package CS::Model::Score;
use Mojo::Base 'MojoX::Model';

use List::Util 'min';

sub scoreboard {
  my ($self, $round) = @_;
  my $db = $self->app->pg->db;

  my $r = $db->query('select max(round) + 1 from scoreboard')->array->[0] // 0;
  $round //= $db->query('select max(n) - 1 from rounds')->array->[0];
  $self->_scoreboard($_) for $r .. $round;
}

sub _scoreboard {
  my ($self, $r) = @_;
  $self->app->log->debug("Calc scoreboard for round #$r");
  $self->app->pg->db->query(
    q{
    insert into scoreboard
    select $1 as round, rank() over(order by score desc) as n, sc.*
    from (
      select
        fp.team_id, round(sum(sla * score)::numeric, 2) as score,
        json_agg(json_build_object(
          'id', fp.service_id,
          'flags', coalesce(f.flags, 0),
          'fp', round(fp.score::numeric, 2),
          'sla', round(100 * s.sla::numeric, 2),
          'status', status,
          'stdout', stdout
        ) order by id) as services
      from
        (select team_id, service_id, score from score where round = $1) as fp
        join (
          select team_id, service_id,
          case when successed + failed = 0 then 1 else (successed::double precision / (successed + failed)) end as sla
          from sla where round = $1
        ) as s using (team_id, service_id)
        left join (
          select sf.team_id, f.service_id, count(sf.data) as flags
          from stolen_flags as sf join flags as f using (data)
          where sf.round <= $1
          group by sf.team_id, f.service_id
        ) as f using (team_id, service_id)
        left join (select team_id, service_id, status, stdout from runs where round = $1) as r using (team_id, service_id)
        join services on fp.service_id = services.id
      group by team_id
    ) as sc
}, $r
  );
}

sub sla {
  my ($self, $round) = @_;
  my $db = $self->app->pg->db;

  my $r = $db->query('select max(round) + 1 from sla')->array->[0];
  $round //= $db->query('select max(n) - 1 from rounds')->array->[0];
  $self->_sla($_) for $r .. $round;
}

sub _sla {
  my ($self, $r) = @_;
  $self->app->log->debug("Calc SLA for round #$r");

  my $db = $self->app->pg->db;
  my $state = $db->query('select * from sla where round = ?', $r - 1)
    ->hashes->reduce(sub { $a->{$b->{team_id}}{$b->{service_id}} = $b; $a; }, {});

  $db->query('
    with r as (select team_id, service_id, status from runs where round = ?),
    teams_x_services as (
      select teams.id as team_id, services.id as service_id
      from teams cross join services
    )
    select * from teams_x_services left join r using (team_id, service_id)', $r)->hashes->map(
    sub {
      my $field = ($_->{status} // 110) == 101 ? 'successed' : 'failed';
      ++$state->{$_->{team_id}}{$_->{service_id}}{$field};
    }
  );

  $self->_update_sla_state($r, $state);
}

sub flag_points {
  my ($self, $round) = @_;
  my $db = $self->app->pg->db;

  my $r = $db->query('select max(round) + 1 from score')->array->[0];
  $round //= $db->query('select max(n) - 1 from rounds')->array->[0];
  $self->_flag_points($_) for $r .. $round;
}

sub _flag_points {
  my ($self, $r) = @_;
  $self->app->log->debug("Calc FP for round #$r");

  my $db = $self->app->pg->db;
  my $state = $db->query('select * from score where round = ?', $r - 1)
    ->hashes->reduce(sub { $a->{$b->{team_id}}{$b->{service_id}} = $b->{score}; $a; }, {});
  my $flags = $db->query('
    select f.data, f.service_id, f.team_id as victim_id, sf.team_id
    from flags as f join stolen_flags as sf using (data)
    where sf.round = ? order by sf.ts
    ', $r)->hashes;

  my $scoreboard = $db->query(
    'select rank() over(order by score desc) as n, team_id
      from (select team_id,
          round(sum(100 * score * (case when successed + failed = 0 then 1
          else (successed::double precision / (successed + failed)) end))::numeric, 2) as score
      from score join sla using (round, team_id, service_id)
      where round = ?
      group by team_id) as tmp', $r - 1
  )->hashes->reduce(sub { $a->{$b->{team_id}} = $b->{n}; $a; }, {});

  my $jackpot = 0 + keys %{$self->app->teams};
  for my $flag (@$flags) {
    my ($v, $t) = @{$scoreboard}{@{$flag}{qw/victim_id team_id/}};

    my $amount = $t >= $v ? $jackpot : exp(log($jackpot) * ($v - $jackpot) / ($t - $jackpot));
    $state->{$flag->{team_id}}{$flag->{service_id}} += $amount;
    $state->{$flag->{victim_id}}{$flag->{service_id}} -=
      min($amount, $state->{$flag->{victim_id}}{$flag->{service_id}});
  }

  $self->_update_score_state($r, $state);
}

sub _update_sla_state {
  my ($self, $r, $state) = @_;

  my $db = $self->app->pg->db;
  my $tx = $db->begin;
  for my $team_id (keys %$state) {
    for my $service_id (keys %{$state->{$team_id}}) {
      my $s = $state->{$team_id}{$service_id};

      my $sql = 'insert into sla (round, team_id, service_id, successed, failed) values (?, ?, ?, ?, ?)';
      $db->query($sql, $r, $team_id, $service_id, $s->{successed} // 0, $s->{failed} // 0);
    }
  }
  $tx->commit;
}

sub _update_score_state {
  my ($self, $r, $state) = @_;

  my $db = $self->app->pg->db;
  my $tx = $db->begin;
  for my $team_id (keys %$state) {
    for my $service_id (keys %{$state->{$team_id}}) {
      my $sql = 'insert into score (round, team_id, service_id, score) values (?, ?, ?, ?)';
      $db->query($sql, $r, $team_id, $service_id, $state->{$team_id}{$service_id});
    }
  }
  $tx->commit;
}

1;
