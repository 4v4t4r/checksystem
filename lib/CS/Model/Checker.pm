package CS::Model::Checker;
use Mojo::Base 'MojoX::Model';

use File::Spec;
use IPC::Run qw/start timeout/;
use List::Util qw/all min/;
use Mojo::Collection 'c';
use Mojo::Util qw/dumper trim/;
use Proc::Killfam;
use Time::HiRes qw/gettimeofday tv_interval/;
use Time::Piece;

has statuses => sub { [[up => 101], [corrupt => 102], [mumble => 103], [down => 104]] };
has status2name => sub {
  return {map { $_->[1] => $_->[0] } @{$_[0]->statuses}};
};

sub vulns {
  my ($self, $service) = @_;

  my $info = $self->_run([$service->{path}, 'info'], $service->{timeout});
  return (1, '1') unless $info->{exit_code} == 101;

  $info->{stdout} =~ /^vulns:(.*)$/m;
  my $vulns = trim($1 // '');
  return (1, '1') unless $vulns =~ /^[0-9:]+$/;

  return (0 + split(/:/, $vulns), $vulns);
}

sub check {
  my ($self, $job, $round, $team, $service, $flag, $old_flag, $vuln) = @_;
  my $result = {vuln => $vuln};
  my $db = $job->app->pg->db;

  if (my $bot_info = $job->app->bots->{$team->{id}}) {
    my $bot = $bot_info->{$service->{id}} // {sla => 0, attack => 1, defense => 0};
    my $r = $self->_run_bot($db, $bot, $team, $service, $round);
    return $self->_finish($job, {%$result, %$r}, $db);
  }

  my $host = $team->{host};
  if (my $cb = $job->app->config->{cs}{checkers}{hostname}) { $host = $cb->($team, $service) }

  # Check
  my $cmd = [$service->{path}, 'check', $host];
  $result->{check} = $self->_run($cmd, min($service->{timeout}, $self->_next_round_start($db, $round)));
  return $self->_finish($job, $result, $db) if $result->{check}{slow} || $result->{check}{exit_code} != 101;

  # Put
  $cmd = [$service->{path}, 'put', $host, $flag->{id}, $flag->{data}, $vuln->{n}];
  $result->{put} = $self->_run($cmd, min($service->{timeout}, $self->_next_round_start($db, $round)));
  return $self->_finish($job, $result, $db) if $result->{put}{slow} || $result->{put}{exit_code} != 101;
  (my $id = $result->{put}{stdout}) =~ s/\r?\n$//;
  $flag->{id} = $result->{put}{fid} = $id if $id;

  # Get 1
  $cmd = [$service->{path}, 'get', $host, $flag->{id}, $flag->{data}, $vuln->{n}];
  $result->{get_1} = $self->_run($cmd, min($service->{timeout}, $self->_next_round_start($db, $round)));
  return $self->_finish($job, $result, $db) if $result->{get_1}{slow} || $result->{get_1}{exit_code} != 101;

  # Get 2
  if ($old_flag) {
    $cmd = [$service->{path}, 'get', $host, $old_flag->{id}, $old_flag->{data}, $vuln->{n}];
    $result->{get_2} = $self->_run($cmd, min($service->{timeout}, $self->_next_round_start($db, $round)));
  }
  return $self->_finish($job, $result, $db);
}

sub _finish {
  my ($self, $job, $result, $db) = @_;

  my ($round, $team, $service, $flag, undef, $vuln) = @{$job->args};
  my ($stdout, $status) = ('');

  # Prepare result for runs
  if (c(qw/get_2 get_1 put check/)->first(sub { defined $result->{$_}{slow} })) {
    $result->{error} = 'Job is too old!';
    $status = 104;
  } else {
    my $state = c(qw/get_2 get_1 put check/)->first(sub { defined $result->{$_}{exit_code} });
    $status = $result->{$state}{exit_code};
    $stdout = $result->{$state}{stdout} if $status != 101;
  }

  $job->finish($result);

  # Save result
  eval {
    $db->query(
      'insert into runs (round, team_id, service_id, vuln_id, status, result, stdout)
      values (?, ?, ?, ?, ?, ?, ?)', $round, $team->{id}, $service->{id}, $vuln->{id}, $status,
      {json => $result}, $stdout
    );
  };
  $self->app->log->error("Error while insert check result: $@") if $@;

  # Check, put and get was ok, save flag
  return unless ($result->{get_1}{exit_code} // 0) == 101;
  my $id = $result->{put}{fid} // $flag->{id};
  eval {
    $db->insert(
      flags => {
        data       => $flag->{data},
        id         => $id,
        round      => $round,
        team_id    => $team->{id},
        service_id => $service->{id},
        vuln_id    => $vuln->{id}
      }
    );
  };
  $self->app->log->error("Error while insert flag: $@") if $@;
}

sub _next_round_start {
  my ($self, $db, $round) = @_;

  return $db->query('select extract(epoch from ts + ?::interval - now()) from rounds where n = ?',
    $self->app->config->{cs}{round_length}, $round)->array->[0];
}

sub _run {
  my ($self, $cmd, $timeout) = @_;
  my ($stdout, $stderr);

  return {slow => 1} if $timeout <= 0;

  my $path = File::Spec->rel2abs($cmd->[0]);
  my (undef, $cwd) = File::Spec->splitpath($path);
  $cmd->[0] = $path;

  $self->app->log->debug("Run '@$cmd' with timeout $timeout");
  my ($t, $h) = timeout($timeout);
  my $start = [gettimeofday];
  eval {
    $h = start $cmd, \undef, \$stdout, \$stderr, 'init', sub { chdir $cwd }, $t;
    $h->finish;
  };
  my $result = {
    command   => "@$cmd",
    elapsed   => tv_interval($start),
    exception => $@,
    exit      => {value => $?, code => $? >> 8, signal => $? & 127, coredump => $? & 128},
    stderr => ($stderr // '') =~ s/\x00//gr,
    stdout => ($stdout // '') =~ s/\x00//gr,
    timeout => 0
  };
  $result->{exit_code} = ($@ || all { $? >> 8 != $_ } (101, 102, 103, 104)) ? 110 : $? >> 8;

  if ($@ && $@ =~ /timeout/i) {
    $result->{timeout}   = 1;
    $result->{exit_code} = 104;
    my $pid = $h->{KIDS}[0]{PID};
    my $n = killfam 9, $pid;
    $self->app->log->debug("Kill all sub process for $pid => $n");
  }

  $result->{ts} = scalar localtime;
  return $result;
}

sub _run_bot {
  my ($self, $db, $bot, $team, $service, $round) = @_;
  my $app    = $self->app;
  my $result = {};

  my $exit_code = rand() < $bot->{sla} ? 101 : 104;
  for my $command (qw/check put get_1 get_2/) {
    $result->{$command} = {
      command   => dumper($bot),
      elapsed   => 0,
      exception => undef,
      exit      => {value => 0, code => 0, signal => 0, coredump => 0},
      stderr    => '',
      stdout    => '',
      timeout   => 0,
      ts        => scalar(localtime),
      exit_code => $exit_code
    };
  }
  return $result unless $exit_code == 101;

  my $game_time = $app->model('util')->game_time;
  my $now       = localtime->epoch;
  my $current   = ($now - $game_time->{start}) / ($game_time->{end} - $game_time->{start});
  return $result unless $bot->{attack} < $current;

  # Hack
  my $flags = $db->query(
    'select data from flags where service_id = $1 and round < $3 and team_id in
      (select team_id from bots where service_id = $1 and team_id != $2 and defense > $4)', $service->{id},
    $team->{id}, $round, $current
  )->arrays;
  for my $flag (@$flags) {
    $app->model('flag')->accept($team->{id}, $flag->[0], sub { });
  }

  return $result;
}

1;
