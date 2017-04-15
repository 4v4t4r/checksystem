package CS::Command::init_db;
use Mojo::Base 'Mojolicious::Command';

has description => 'Init db schema';

sub run {
  my $app = shift->app;
  my $db  = $app->pg->db;

  # Teams
  for my $team (@{$app->config->{teams}}) {
    $db->insert(teams => {%{$team}{qw/name network host/}});
  }

  # Services
  for my $service (@{$app->config->{services}}) {
    my ($n, $vulns) = $app->model('checker')->vulns($service);
    my $name = $service->{name};
    my $id = $db->insert(services => {name => $name, vulns => $vulns}, {returning => 'id'})->hash->{id};
    $db->insert(vulns => {service_id => $id, n => $_}) for 1 .. $n;
  }

  # Bots
  my $team_id = 0;
  for my $team (@{$app->config->{teams}}) {
    ++$team_id;
    if (my $bot = $team->{bot}) {
      my $service_id = 0;
      for (@$bot) {
        ++$service_id;
        next unless keys %$_;
        my $data = {%$_, team_id => $team_id, service_id => $service_id};
        $db->insert(bots => $data);
      }
    }
  }

  # Scores
  $db->insert(rounds => {n => 0});
  $db->query('
    insert into flag_points (round, team_id, service_id, amount)
    select 0, teams.id, services.id, ? from teams cross join services', 0 + @{$app->config->{teams}});
  $db->query('
    insert into sla (round, team_id, service_id, successed, failed)
    select 0, teams.id, services.id, 0, 0 from teams cross join services'
  );
  $app->model('score')->scoreboard($db, 0);

  # Flags
  if (open my $f, '<', 'flags.csv') {
    my $dbh = $db->dbh;
    $dbh->do("copy flags(data,id,round,team_id,service_id,vuln_id) from stdin with delimiter ','");
    while (my $line = $f->getline) {
      $dbh->pg_putcopydata($line);
    }
    $dbh->pg_putcopyend;
  }
}

1;
