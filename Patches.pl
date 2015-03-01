#!/opt/perl

package Mojolicious::Command::crontab;

use Mojo::Base 'Mojolicious::Command';
use Sys::Hostname qw(hostname);
use FindBin qw($Bin $Script);

has description => 'Example crontab command';
has usage       => "Usage: APPLICATION crontab\n";

sub run {
    my ($self, @args) = @_;

    say("5       0       *       *       *       $Bin/$Script enqueue query");
}

package Mojolicious::Command::enqueue;

use Mojo::Base 'Mojolicious::Command';
use Sys::Hostname qw(hostname);

has description => 'enqueue patch update check for this host';
has usage       => "Usage: APPLICATION enqueue TASK\n";

sub run {
    my ($self, @args) = @_;

    die("No TASK given\n") unless $args[0];

    $self->app->minion->enqueue($args[0] => [hostname]);
}

package main;

use Mojolicious::Lite;
use Mojo::JSON qw(decode_json);
use Mojo::Util qw(slurp);
use Mojo::Pg;
use Sys::Hostname qw(hostname);
use File::Temp qw(tempfile);

plugin Config => {file => '/opt/patches.config'};
app->secrets([app->config->{secret}]);

plugin Minion => {Pg => app->config->{pg_string}};
plugin qw(bootstrap3);

helper pg => sub { state $pg = Mojo::Pg->new(app->config->{pg_string}) };

app->minion->on(retry => sub {
    my ($minion, $job_id) = @_;

    $minion->backend->retry_job($job_id);

    sleep(7);
});

app->minion->add_task(reboot => sub {
    my $job = shift;
    my $hostname = shift;

    # Would be nice to be able to enqueue a specific worker?
    unless ($hostname eq hostname) {
        $job->finish({ status => "retry" });

        $job->minion->emit(retry => $$job{id});

        return;
    }

    eval {
        my $ret = system("/usr/bin/sudo /sbin/init 6");

        my $exit = $?;
        my $exit_ret = $? >> 8;
    
        if ($ret) {
            if ($? == -1) {
                die("failed to execute init 6: $!\n");
            }
            else {
                die(sprintf("init 6 exited with value %d\n", $exit_ret));
            }
        }
    };
    if ($@) {
        my $err = $@;
        chomp($err);
        $job->finish({ status => $err });
    }
    else {
        $job->finish({ status => "Rebooting" });
    }
});

app->minion->add_task(query => sub {
    my $job = shift;
    my $hostname = shift;

    # Would be nice to be able to enqueue a specific worker?
    unless ($hostname eq hostname) {
        $job->finish({ status => "retry" });

        $job->minion->emit(retry => $$job{id});

        return;
    }

    eval {
        my $ret = system("/usr/bin/yum --quiet check-update 1>/dev/null");

        my $exit = $?;
        my $exit_ret = $? >> 8;
    
        if ($ret) {
            if ($? == -1) {
                die("failed to execute yum: $!\n");
            }
            elsif ($? & 127) {
                die(sprintf("yum died with signal %d, %s coredump\n", ($? & 127),  ($? & 128) ? 'with' : 'without'));
            }
            elsif (100 == $exit_ret)  {
                die("updates available\n");
            }
            else {
                die(sprintf("yum exited with value %d\n", $exit_ret));
            }
        }
    };
    if ($@) {
        my $err = $@;
        chomp($err);
        $job->finish({ status => $err });
    }
    else {
        $job->finish({ status => "no updates" });
    }
});

app->minion->add_task(update => sub {
    my $job = shift;
    my $hostname = shift;

    # Would be nice to be able to enqueue a specific worker?
    unless ($hostname eq hostname) {
        $job->finish({ status => "retry" });

        $job->minion->emit(retry => $$job{id});

        return;
    }

    my ($output, $errput); 
    eval {
        (undef, $output) = tempfile("yum_update_stdout_XXXXXX", TMPDIR => 1, UNLINK => 0);
        (undef, $errput) = tempfile("yum_update_stderr_XXXXXX", TMPDIR => 1, UNLINK => 0);

        my $ret = system("/usr/bin/sudo /usr/bin/yum -y update 1>$output 2>$errput");

        my $exit = $?;
        my $exit_ret = $? >> 8;
    
        if ($ret) {
            if ($? == -1) {
                die("failed to execute yum: $!\n");
            }
            elsif ($? & 127) {
                die(sprintf("yum died with signal %d, %s coredump\n", ($? & 127),  ($? & 128) ? 'with' : 'without'));
            }
            else {
                die(sprintf("yum exited with value %d\n", $exit_ret));
            }
        }
    };
    if ($@) {
        my $err = $@;
        chomp($err);
        $job->finish({ status => $err, stdout => slurp($output), stderr => slurp($errput) });
    }
    else {
        $job->finish({ status => "Yum finished", stdout => slurp($output), stderr => slurp($errput) });
    }
});

get '/' => sub {
    my $c = shift;

    $c->render(template => 'index');
};

post '/' => sub {
    my $c = shift;

    if ($c->param("password")) {
        if ($c->param("password") eq $c->app->config->{password}) {
            $c->session(password => $c->param("password"));
            $c->session(expiration => 600);

            my $url = $c->url_for('/boxen');
            return($c->redirect_to($url));
        }
    }

    $c->render(template => 'index');
};

under sub {
    my $c = shift;
    
    # Authenticated
    my $password = $c->session("password") || "";
    return 1 if $password eq $c->app->config->{password};
    
    # Not authenticated
    $c->flash(error => "Please login");

    my $url = $c->url_for('/');
    $c->redirect_to($url);

    return undef;
};

get '/boxen' => sub {
    my $c = shift;

    my $db = $c->pg->db;

    my @workers = ();

    # Is there an API for this?
    my $results = $db->query("select * from minion_workers");
    while (my $worker = $results->hash) {
        my $active  = $db->query("select count(*) from minion_jobs where worker = ? and state = 'active'", $$worker{id})->array->[0];
        my $hash = $db->query("select result, finished from minion_jobs where worker = ? and state = 'finished' order by finished desc limit 1", $$worker{id})->expand->hash;
    
        if ($hash) {
            my $status = $hash->{result}{status};
            my $finished = $hash->{finished};

            my $action = "";
            my $update = "";

            my $query = $c->url_for("/query?hostname=$$worker{host}")->to_abs;
            $query = qq(<a href="#" class="btn btn-primary" role="button" onclick="if (confirm('Query: Are you sure')) { location ='$query' }">Query</a>);

            if ("updates available" eq $status) {
                $status = "Updates Available [$finished]";

                $update = $c->url_for("/update?hostname=$$worker{host}")->to_abs;
                $update = qq(<a href="#" class="btn btn-primary" role="button" onclick="if (confirm('Update: Are you sure')) { location ='$update' }">Update</a>);
            }
            elsif ("no updates" eq $status) {
                $status = "No Updates [$finished]";
            }

            my $reboot = $c->url_for("/reboot?hostname=$$worker{host}")->to_abs;
            $reboot = qq(<a href="#" class="btn btn-primary" role="button" onclick="if (confirm('Reboot: Are you sure')) { location ='$reboot' }">Reboot</a>);

            $action = qq(
                <div class="btn-group" role="group" aria-label="...">
                    $query
                    $update
                    $reboot
                </div>
            );

            my $row = { hostname => "$$worker{host} [$active]", status => $status, action => $action };
            push(@workers, $row);
        }
        else {
            my $reboot = $c->url_for("/reboot?hostname=$$worker{host}")->to_abs;
            my $query = $c->url_for("/query?hostname=$$worker{host}")->to_abs;

            $query = qq(<a href="#" class="btn btn-primary" role="button" onclick="if (confirm('Query: Are you sure')) { location ='$query' }">Query</a>);
            $reboot = qq(<a href="#" class="btn btn-primary" role="button" onclick="if (confirm('Reboot: Are you sure')) { location ='$reboot' }">Reboot</a>);

            my $action = qq(
                <div class="btn-group" role="group" aria-label="...">
                    $query
                    $reboot
                </div>
            );

            my $row = { hostname => "$$worker{host} [0]", status => "No Results", action => $action };
            push(@workers, $row);
        }
    }

    $c->render(template => 'boxen', workers => \@workers, now => scalar(localtime(time)));
};

get '/query' => sub {
    my $c = shift;

    my $hostname = $c->param("hostname");

    $c->app->minion->enqueue(query => [$hostname]) if $hostname;

    $c->flash(message => "Query scheduled: $hostname");

    my $url = $c->url_for('/boxen');
    return($c->redirect_to($url));
};

get '/update' => sub {
    my $c = shift;

    my $hostname = $c->param("hostname");

    $c->app->minion->enqueue(update => [$hostname]) if $hostname;

    $c->flash(message => "Update scheduled: $hostname");

    my $url = $c->url_for('/boxen');
    return($c->redirect_to($url));
};

get '/reboot' => sub {
    my $c = shift;

    my $hostname = $c->param("hostname");

    $c->app->minion->enqueue(reboot => [$hostname]) if $hostname;

    $c->flash(message => "Reboot scheduled: $hostname");

    my $url = $c->url_for('/boxen');
    return($c->redirect_to($url));
};

app->start;

__DATA__

@@ layouts/default.html.ep
<!DOCTYPE html>
  <head>
    %= asset "bootstrap.css"
    %= asset "bootstrap.js"

    <title>Patches</title>
  </head>
  <body>
    <style>
        body {
          padding-top: 50px;
        }
        .starter-template {
          padding: 40px 15px;
          text-align: center;
        }
    </style>
    <nav class="navbar navbar-inverse navbar-fixed-top">
      <div class="container">
        <div class="navbar-header">
          <button type="button" class="navbar-toggle collapsed" data-toggle="collapse" data-target="#navbar" aria-expanded="false" aria-controls="navbar">
            <span class="sr-only">Toggle navigation</span>
            <span class="icon-bar"></span>
            <span class="icon-bar"></span>
            <span class="icon-bar"></span>
          </button>
          <a class="navbar-brand" href="#">Patches</a>
        </div>
      </div>
    </nav>

    <div class="container">
        <%= content %>
    </div><!-- /.container -->
  </body>
</html>

@@ index.html.ep
% layout 'default';
<div class="starter-template">
  <h1>Login</h1>
  <form class="form-inline" method="post">
    <div class="form-group">
      <label class="sr-only" for="password">Password</label>
      <input type="password" class="form-control" id="password" name="password" placeholder="Password">
    </div>
    <button type="submit" class="btn btn-default">Sign in</button>
  </form>
</div>

@@ boxen.html.ep
% layout 'default';
<h1><a href="/boxen">Boxen</a></h1>
<p><%= stash('now') %></p>

% if (flash('message')) {
    <div class="row clearfix" style="margin-bottom: 20px">
        <div class="col-lg-12">
            <div class="alert alert-info" role="alert"><%== flash('message') %></div>
        </div>
    </div>
% }

% if (stash('workers') && scalar @{ stash('workers') }) {
    <table class="table table-hover">
      <thead>
        <tr>
          <th>#</th>
          <th>Hostname</th>
          <th>Status</th>
          <th>Action</th>
        </tr>
      </thead>
      <tbody>

    % for (my ($i, $j) = (0, 1); $i < @{ stash('workers') }; ++$i, ++$j) {
    <tr>
      <th scope="row"><%= $j %></th>
      <td><%= stash('workers')->[$i]{hostname} %></td>
      <td><%= stash('workers')->[$i]{status} %></td>
      <td><%== stash('workers')->[$i]{action} %></td>
    </tr>
   % }
  </tbody>
</table>
% } else {
   Nothing found.
% }
