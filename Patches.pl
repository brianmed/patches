#!/opt/perl

package Patches::Command::patches;

use Mojo::Base 'Mojolicious::Commands';

has description => 'Patches';
has hint        => <<EOF;

See 'APPLICATION patches help COMMAND' for more information on a specific
command.
EOF
has message    => sub { "Commands:\n" };
has namespaces => sub { ['Patches::Command::patches'] };

sub help { shift->run(@_) }

package Patches::Command::patches::migrate;

use Mojo::Base 'Mojolicious::Command';

has description => 'migrate database to latest version';
has usage       => "Usage: APPLICATION patches migrate\n";

sub run {
    my ($self) = @_;

    $self->app->sql->migrations->from_file($self->app->home->rel_file('migrate.sql'))->migrate;
}

package Patches::Command::patches::remote;

use Mojo::Base 'Mojolicious::Command';

has description => 'add remote box to the db';
has usage       => "Usage: APPLICATION patches remote HOSTNAME URL API_KEY\n";

sub run {
    my ($self, $hostname, $url, $api_key) = @_;

    die("No HOSTNAME given\n") unless $hostname;
    die("No URL given\n") unless $url;
    die("No API_KEY given\n") unless $api_key;

    $self->app->sql->db->query('INSERT INTO manager (hostname, url, api_key) VALUES (?, ?, ?)', $hostname, $url, $api_key);
}

package Patches::Task;

use Mojo::Util qw(slurp);
use File::Temp qw(tempfile);

sub reboot {
    my $c = shift;

    eval {
        my $system = "/usr/bin/sudo /sbin/init 6";
        $c->app->log->debug($system);
        my $ret = system($system);

        my $exit = $?;
        my $exit_ret = $? >> 8;
    
        if ($ret) {
            if ($exit == -1) {
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
        $c->app->sql->db->query('INSERT INTO status (status) VALUES (?)', $err);
    }
    else {
        $c->app->sql->db->query('INSERT INTO status (status) VALUES (?)', "Rebooting");
    }
}

sub query {
    my $c = shift;

    my ($output);
    my ($errput);

    my $ret = {};

    eval {
        (undef, $output) = tempfile("yum_query_stdout_XXXXXX", TMPDIR => 1, UNLINK => 0);
        (undef, $errput) = tempfile("yum_query_stderr_XXXXXX", TMPDIR => 1, UNLINK => 0);

        my $system = "/usr/bin/yum check-update 1>$output 2>$errput";
        $c->app->log->debug($system);
        my $ret = system($system);

        my $exit = $?;
        my $exit_ret = $? >> 8;

        if ($ret) {
            if ($exit == -1) {
                die("failed to execute yum: $!\n");
            }
            elsif ($exit & 127) {
                die(sprintf("yum died with signal %d, %s coredump\n", ($exit & 127),  ($exit & 128) ? 'with' : 'without'));
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

        $ret = { status => $err, stdout => slurp($output), stderr => slurp($errput) };

        $c->app->sql->db->query('INSERT INTO status (status, stdout, stderr) VALUES (?, ?, ?)', $err, slurp($output), slurp($errput));
    }
    else {
        $ret = { status => "no updates", stdout => slurp($output), stderr => slurp($errput) };

        $c->app->sql->db->query('INSERT INTO status (status, stdout, stderr) VALUES (?, ?, ?)', "no updates", slurp($output), slurp($errput));
    }

    return $ret;
}

sub update {
    my $c = shift;

    my ($output, $errput); 
    eval {
        (undef, $output) = tempfile("yum_update_stdout_XXXXXX", TMPDIR => 1, UNLINK => 0);
        (undef, $errput) = tempfile("yum_update_stderr_XXXXXX", TMPDIR => 1, UNLINK => 0);

        my $system = "/usr/bin/sudo /usr/bin/yum -y update 1>$output 2>$errput";
        $c->app->log->debug($system);
        my $ret = system($system);

        my $exit = $?;
        my $exit_ret = $? >> 8;
    
        if ($ret) {
            if ($exit == -1) {
                die("failed to execute yum: $!\n");
            }
            elsif ($exit & 127) {
                die(sprintf("yum died with signal %d, %s coredump\n", ($exit & 127),  ($exit & 128) ? 'with' : 'without'));
            }
            else {
                die(sprintf("yum exited with value %d\n", $exit_ret));
            }
        }
    };
    if ($@) {
        my $err = $@;
        chomp($err);

        $c->app->sql->db->query('INSERT INTO status (status, stdout, stderr) VALUES (?, ?, ?)', $err, slurp($output), slurp($errput));
    }
    else {
        $c->app->sql->db->query('INSERT INTO status (status, stdout, stderr) VALUES (?, ?, ?)', "Yum finished", slurp($output), slurp($errput));
    }
}

package main;

use Mojolicious::Lite;
use Mojo::JSON qw(decode_json);
use Mojo::SQLite;
use Sys::Hostname qw(hostname);

plugin Config => {file => '/opt/patches.config'};
app->secrets([app->config->{secret}]);

plugin AccessLog => {log => app->home->rel_file('log/access.log'), format => '%h %l %u %t "%r" %>s %b %D "%{Referer}i" "%{User-Agent}i"'};

plugin qw(Bootstrap3);

helper sql => sub { state $sql = Mojo::SQLite->new(app->config->{sqlite_string}) };

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

under(sub {
    my $c = shift;

    if ($c->current_route =~ m/^api_/) {
        unless ($c->req->json) {
            $c->render(json => {status => "error", data => { message => "No JSON found" }});

            return undef;
        }

        my $api_key = $c->req->json->{api_key};

        unless ($api_key) {
            $c->render(json => {status => "error", data => { message => "No API Key found" }});

            return undef;
        }

        unless ($api_key eq app->config->{api_key}) {
            $c->render(json => {status => "error", data => { message => "Credentials mis-match" }});

            return undef;
        }

        return 1;
    }
    
    # Authenticated
    my $password = $c->session("password") || "";
    return 1 if $password eq $c->app->config->{password};
    
    # Not authenticated
    $c->flash(error => "Please login");

    my $url = $c->url_for('/');
    $c->redirect_to($url);

    return undef;
});

get '/boxen' => sub {
    my $c = shift;

    my $db = $c->sql->db;

    my $boxen = $c->sql->db->query("SELECT * FROM manager ORDER BY id")->hashes->to_array;

    my @boxen = ();

    foreach my $box (@{ $boxen }) {
        my ($reboot, $query, $update);

        $query = qq(<a href="#" data-idx="$box->{id}" class="btn btn-primary" role="button" onclick="boxenTask(this, $box->{id}, 'query')">Query</a>);
        $update = qq(<a href="#" data-idx="$box->{id}" class="btn btn-primary" role="button" onclick="if (confirm('Update: Are you sure')) { boxenTask(this, $box->{id}, 'update') }">Update</a>);
        $reboot = qq(<a href="#" data-idx="$box->{id}" class="btn btn-primary" role="button" onclick="if (confirm('Reboot: Are you sure')) { boxenTask(this, $box->{id}, 'reboot') }">Reboot</a>);

        my $action = qq(
            <div class="btn-group" role="group" aria-label="...">
                $query
                $update
                $reboot
            </div>
        );

        my $row = { id => $box->{id}, hostname => "$$box{hostname}", status => "No Results", action => $action };
        push(@boxen, $row);
    }

    $c->render(template => "boxen", boxen => \@boxen, now => scalar(localtime(time)));

    return;
};

get "/v1/remote/:task/:box_id" => sub {
    my $c = shift->render_later;

    $c->inactivity_timeout(3600);

    my $task = $c->param("task");
    my $box_id = $c->param("box_id");

    my $box = $c->sql->db->query("SELECT * FROM manager WHERE id = ?", $box_id)->hash;

    unless ($box) {
        $c->render(json => { message => "Box not found: $box_id" });

        return;
    }

    $c->ua->inactivity_timeout(3600)->post("$box->{url}/v1/task" => json => { api_key => $box->{api_key}, task => $task } => sub {
        my ($ua, $tx) = @_;

        if ($tx->success) {
            $c->render(json => $tx->res->json);
        } else {
            $c->app->log->debug($c->dumper($tx));
            $c->render(json => { success => 0, message => "Error: " . $tx->error->code });
        }
    });
};

post '/v1/task' => sub {
    my $c = shift;

    $c->inactivity_timeout(3600);

    my $task = $c->req->json->{task};

    my $sub = \&{ "Patches::Task::$task" };
       
    $sub->($c, $task);

    my $hash = $c->sql->db->query("select status from status order by id desc limit 1")->hash;

    $c->render(json => {success => 1, message => $hash->{status}});
} => "api_task";

push @{app->commands->namespaces}, 'Patches::Command';

app->start;

__DATA__

@@ layouts/default.html.ep
<!DOCTYPE html>
  <head>
    %= asset "bootstrap.css"
    %= asset "bootstrap.js"
    %= asset "font-awesome4.css"

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

% if (stash('boxen') && scalar @{ stash('boxen') }) {
    <table class="table table-hover">
      <thead>
        <tr>
          <th>#</th>
          <th>Hostname</th>
          <th><img src="refresh.png" width="12px" id="refresh"> Status</th>
          <th>Action</th>
        </tr>
      </thead>
      <tbody>

    % for (my ($i, $j) = (0, 1); $i < @{ stash('boxen') }; ++$i, ++$j) {

    % my $idx = stash('boxen')->[$i]{id};
    <tr>
      <th scope="row"><%= $j %></th>
      <td><%= stash('boxen')->[$i]{hostname} %></td>
      <td>
            <img style="display:none" src="spinner.gif" width="12px" data-idx="<%= $idx %>" id="refresh_<%= $idx %>"> 
            <span data-idx="<%= $idx %>" id="status_<%= $idx %>"> <%= stash('boxen')->[$i]{status} %> </span>
      </td>
      <td><%== stash('boxen')->[$i]{action} %></td>
    </tr>
   % }
  </tbody>
</table>
% } else {
   Nothing found.
% }

<script>
    $("#refresh").on("click", function (e) {
        $("img[id^='refresh_']").each(function (e) {
            refreshStatus(this, "query");
        });
    });

    $("img[id^='refresh_']").on("click", function (e) {
        refreshStatus(this, "query");
    });

    function refreshStatus(elem, task) {
        var idx = $(elem).data('idx');

        $('#status_' + idx).hide();
        $('#refresh_' + idx).show();

        $.getJSON("/v1/remote/" + task + "/" + idx, function(data) {
            $('#status_' + idx).html(data.message);

            $('#refresh_' + idx).hide();
            $('#status_' + idx).show();
        });
    }

    function boxenTask(elem, idx, task) {
        refreshStatus(elem, task);
    }
</script>

@@ spinner.gif (base64)

R0lGODlhEAAQAPIAAP///wAAAMLCwkJCQgAAAGJiYoKCgpKSkiH/C05FVFNDQVBFMi4wAw
EAAAAh/hpDcmVhdGVkIHdpdGggYWpheGxvYWQuaW5mbwAh+QQJCgAAACwAAAAAEAAQAAAD
Mwi63P4wyklrE2MIOggZnAdOmGYJRbExwroUmcG2LmDEwnHQLVsYOd2mBzkYDAdKa+dIAA
Ah+QQJCgAAACwAAAAAEAAQAAADNAi63P5OjCEgG4QMu7DmikRxQlFUYDEZIGBMRVsaqHwc
tXXf7WEYB4Ag1xjihkMZsiUkKhIAIfkECQoAAAAsAAAAABAAEAAAAzYIujIjK8pByJDMlF
YvBoVjHA70GU7xSUJhmKtwHPAKzLO9HMaoKwJZ7Rf8AYPDDzKpZBqfvwQAIfkECQoAAAAs
AAAAABAAEAAAAzMIumIlK8oyhpHsnFZfhYumCYUhDAQxRIdhHBGqRoKw0R8DYlJd8z0fMD
gsGo/IpHI5TAAAIfkECQoAAAAsAAAAABAAEAAAAzIIunInK0rnZBTwGPNMgQwmdsNgXGJU
lIWEuR5oWUIpz8pAEAMe6TwfwyYsGo/IpFKSAAAh+QQJCgAAACwAAAAAEAAQAAADMwi6IM
KQORfjdOe82p4wGccc4CEuQradylesojEMBgsUc2G7sDX3lQGBMLAJibufbSlKAAAh+QQJ
CgAAACwAAAAAEAAQAAADMgi63P7wCRHZnFVdmgHu2nFwlWCI3WGc3TSWhUFGxTAUkGCbtg
ENBMJAEJsxgMLWzpEAACH5BAkKAAAALAAAAAAQABAAAAMyCLrc/jDKSatlQtScKdceCAjD
II7HcQ4EMTCpyrCuUBjCYRgHVtqlAiB1YhiCnlsRkAAAOwAAAAAAAAAAAA==

@@ refresh.png (base64)

iVBORw0KGgoAAAANSUhEUgAAACAAAAAgCAQAAADZc7J/AAAABGdBTUEAALGPC/xhBQAAAC
BjSFJNAAB6JgAAgIQAAPoAAACA6AAAdTAAAOpgAAA6mAAAF3CculE8AAAAAmJLR0QA/4eP
zL8AAAJSSURBVEjH7ZXPaxNREMc/m0TdJG5Km1ZtDDQBT4LeBEMViulFEcRfUMSDHlUsev
EPqL8OelQP9cdFe/BexaKhAWsttRcVBHvKDzVK2oM0rTHJ7nrI7mb37a4exJvzLo+Z+X7f
mzdvZuAvRfqNTUYhDNRZoY7usgfR0bwJeskwxE4SRIA1KrwnzyxVm0+UEzzhixvcwxnmqa
MLq84C5+k1vMJcY5EBNzzDc5ousLlaTLMXkBmjQVEkkDhO0QFoUmOFhkNX5hRj/ECnRBpC
NoJj3GKTsV9jgRzvqKITZztDZOgCIMkdgqx3X343BeMMjVmOoDisYfYxKQRXIt1x6OaZFe
cDEp65iXEDVSQwQzhK1tg95CLfPQk0ZL9/o5A3WOdI+nyrLm67QkiZxn4+Grke8YF3M05L
SGqBATOEKpOMEmKKKU/4Bi5wgK9oVsIlAnyj1amFGFmi5Kh4EqwjSRDNVg8BJJp8psV/QQ
JCbHbURFt0KjQ9MX0Mo/GCZVOxlVeUKNhWkSLXCXvCNzKBhso9ZFOVEopYR+ORVZeiHGYV
HZ1PbDNVaUoOuMp9enzg/bw0vOat7uQiuGtUvltijFs1e7atCng8Xs0HvoWbnDb2eR53DO
INmjxlmIgDrHCIGTSrDveYBnv6fqISAULsZ5A5pvnAMtDHDrLssiiXuMSMnb19gzqXOSnk
o0GNmtAFyoyIgacp0+AKYf7c1nMMuh8nxSJXrW/jP1jecI64CJaABAeZYNWmjVujLUp7tL
0lz2uW3KdLtJuD6pE2GQUZc7j+K/kF0IQvT3OT8IwAAAAldEVYdGRhdGU6Y3JlYXRlADIw
MTYtMDEtMDlUMTc6NTA6MTgtMDY6MDCfTTKdAAAAJXRFWHRkYXRlOm1vZGlmeQAyMDE1LT
A0LTIxVDA0OjM2OjQ5LTA1OjAwd4E40QAAABl0RVh0U29mdHdhcmUAQWRvYmUgSW1hZ2VS
ZWFkeXHJZTwAAAAASUVORK5CYII=
