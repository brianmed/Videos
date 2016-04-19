#!/opt/perl

package Mojolicious::Command::setup;
use Mojo::Base 'Mojolicious::Command';

use Mojo::Util qw(md5_sum);

has description => 'Setup application';
has usage       => "Usage: APPLICATION setup\n";

sub run {
    my ($self, @args) = @_;
    
    my $app = $self->app;
    
    if ($app->sql->db->query("SELECT name FROM sqlite_master WHERE type='table' AND name='settings'")->hash) {
        die("Already setup\n");
    }
    
    $app->sql->migrations->from_string($self->migration_string)->migrate;

    $app->sql->db->query("INSERT INTO settings VALUES (?, ?, ?)", "app", md5_sum(time), $app->home->rel_dir("."));
}

sub migration_string {
    return qq(
        -- 1 up
        CREATE TABLE settings (id text, secret text, file_dir text);
        CREATE TABLE video (
            video_id INTEGER PRIMARY KEY AUTOINCREMENT,

            video_name TEXT,
            video_path TEXT,

            video_updated DATETIME,
            vidoe_inserted DATETIME DEFAULT CURRENT_TIMESTAMP,

            UNIQUE (video_name, video_path)
        );

        CREATE TRIGGER [UpdatedVideo]
            AFTER UPDATE
            ON video
            FOR EACH ROW
        BEGIN
            UPDATE video SET video_updated=CURRENT_TIMESTAMP WHERE video_id=OLD.video_id;
        END;
        
        -- 1 down
        DROP TABLE app;
        DROP TABLE video;
    );
}

package main;

use Mojolicious::Lite;

use Cwd;
use File::Spec;
use FFmpeg::Stream::Helper;
use Mojo::IOLoop::ReadWriteFork;

# plugin Minion => { SQLite => 'sqlite:_videos.sqlite' };
# plugin ForkCart => { process => ["minion"] };

helper sql => sub { state $sql = Mojo::SQLite->new('sqlite:_videos.sqlite') };
 
app->minion->add_task(transcode => sub {
    my ($job, @args) = @_;
 
    $job->finish;
});

get '/' => sub {
    my $c = shift;
    
    $c->render(template => 'index');
};

get '/video/:video_id' => sub {
    my $c = shift->render_later;
 
    my $video_path = $c->app->sql->db->query("select video_path from video where video_id = ?", $c->param("video_id"))->hash->{video_path};

    my $fork = Mojo::IOLoop::ReadWriteFork->new;
 
    my $fsh = FFmpeg::Stream::Helper->new;
   
    my $command = $fsh->command($video_path);
 
    $c->stash(fork => $fork);
 
    $c->on(finish => sub {
        my $c = shift;

        my $fork = $c->stash('fork') or return;

        $c->app->log->debug("Ending ffmpeg process");

        $fork->kill;
    });
 
    $fork->on(read => sub {
        my($fork, $buffer) = @_;

        $c->write_chunk($buffer);
    });
 
    $c->app->log->info($command);
   
    $fork->start(program => $command);
};

get '/v1/videos' => sub {
    my $c = shift;
    
    $c->render(json => $c->app->sql->db->query("select * from video")->hashes->to_array);
};

post '/v1/video/delete' => sub {
    my $c = shift;

    $c->app->sql->db->query("delete from video where video_id = ?", $c->req->json->{video_id});

    return $c->render(json => { success => 1 });
};

get '/v1/files' => sub {
    my $c = shift;
    
    my $settings = $c->app->sql->db->query("select * from settings")->hash;
    my $file_dir = $settings->{file_dir};

    my $find_it = qr/./;
    if ($c->param("filter[filters][0][value]")) {
        my $found = $c->param("filter[filters][0][value]");

        $find_it = qr/$found/;
    }

    opendir(my $dh, $file_dir) or die("can't opendir $file_dir: $!");
    my @entries = grep({ $_ !~ /^\.\.?$/ && $_ =~ m/$find_it/ } readdir($dh));
    closedir $dh;

    @entries = map({ {entry => $_} } @entries);
    @entries = sort({ $a->{entry} cmp $b->{entry}} @entries);

    unshift(@entries, { entry => ".." });
    # unshift(@entries, { entry => "." }); ## Refresh later

    my $total = scalar(@entries);

    @entries = splice(@entries, $c->param("skip") // 0, $c->param("pageSize") // 15);
    
    # return $c->render(json => { data => \@entries, total => $total } );

    push(my @groups, {
        field => "directory", 
        aggregates => {},
        hasSubgroups => Mojo::JSON::false,
        items => \@entries,
        value => $file_dir,
    });

    # $c->app->log->info($c->dumper(\@groups));
    
    $c->render(json => { groups => \@groups, total => $total });
};

post '/v1/entry' => sub {
    my $c = shift;
    
    my $sql = $c->app->sql;

    my $settings = $sql->db->query("select * from settings")->hash;
    my $file_dir = $settings->{file_dir};

    my $entry = $c->req->json->{entry};
    return $c->render(json => { success => 0, message => "No entry detected" }) unless $entry;

    if ("select" eq $c->req->json->{action}) {
        if (-d "$file_dir/$entry") {
            my $abs_path = Cwd::abs_path("$file_dir/$entry");
            return $c->render(json => { success => 0, message => "No abs path found" }) unless $abs_path;

            $sql->db->query("UPDATE settings SET file_dir = ? WHERE id = 'app'", $abs_path);
            return $c->render(json => { success => 1, directory => 1, file => 0 });
        }

        if (-f "$file_dir/$entry") {
            eval {
                $c->app->sql->db->query(
                    "INSERT INTO video (video_name, video_path) VALUES (?, ?)", 
                    $entry,
                    "$file_dir/$entry"
                );
            };
            if ($@) {
                return $c->render(json => { success => 0, message => $@ });
            }
            else {
                return $c->render(json => { success => 1, directory => 0, file => 1 });
            }
        }

        return $c->render(json => { success => 0, message => "Neither file nor directory" });
    }
};

unless (app->sql->db->query("SELECT name FROM sqlite_master WHERE type='table' AND name='settings'")->hash) {
    die("Please run setup\n") unless "setup" eq $ARGV[0];
}

app->start;

__DATA__

@@ index.html.ep

<!DOCTYPE html>
<html>
<head>
    <title></title>
    <link href="http://kendo.cdn.telerik.com/2016.1.226/styles/kendo.common.min.css" rel="stylesheet" />
    <link href="http://kendo.cdn.telerik.com/2016.1.226/styles/kendo.default.min.css" rel="stylesheet" />
    <link href="http://kendo.cdn.telerik.com/2016.1.226/styles/kendo.mobile.all.min.css" rel="stylesheet" />

    <script src="http://kendo.cdn.telerik.com/2016.1.226/js/jquery.min.js"></script>
    <script src="http://kendo.cdn.telerik.com/2016.1.226/js/kendo.ui.core.min.js"></script>
</head>
<body>

<div data-role="view" id="tabstrip-player" data-title="Videos" data-layout="mobile-tabstrip">

    <center>
        <video id="video" width="90%" controls data-bind="visible: playing" preload="none">
        </video>
    </center>

    <center><div id="addOne"><h3>Use the drawer (upper left) to add</h3></div></center>
    <ul id="videoList"></ul>
</div>

<div data-role="layout" data-id="mobile-tabstrip">
    <header data-role="header">
        <div data-role="navbar">
            <span data-role="view-title"></span>
            <a data-align="right" data-role="button" class="nav-button" data-icon="home" href="#/"></a>
            <a data-role="button" data-rel="drawer" href="#file-drawer" data-icon="share" data-align="left"></a>
        </div>
    </header>

    <p>TabStrip</p>

    <div data-role="footer">
        <div data-role="tabstrip">
            <a href="#tabstrip-player" data-icon="favorites">Player</a>
            <!-- a href="#tabstrip-transcode" data-icon="action">Transcode</a -->
        </div>
    </div>
</div>

<div data-swipe-to-open="false" data-role="drawer" id="file-drawer" data-show="appData.files.show" style="data-views="['tabstrip-player']">
    <ul id="fileList"></ul>
    <div id="filePager"></div>
</div>

<script>
    var appData = kendo.observable({
        videos: {
            dataSource: new kendo.data.DataSource({
                transport: {
                    read: "<%= url_for('/v1/videos')->to_abs %>"
                },
                change: function(e) {
                    if (0 == this.total()) {
                        $('#addOne').show();
                    }
                    else {
                        $('#addOne').hide();
                    }
                }
            }),
        },

        files: {
            dataSource: new kendo.data.DataSource({
                transport: {
                    read: "<%= url_for('/v1/files')->to_abs %>"
                },

                group: { field: "directory" },

                serverPaging: true,
                serverSorting: true,
                serverGrouping: true,
                serverFiltering: true,
                pageSize: 15,

                schema: {
                    groups: function(response) {
                        return response.groups;
                    },
                    total: function(response) {
                        return response.total;
                    },
                    model: {
                        value: {
                            type: "string",
                        },
                    },
                },
            }),

            show: function() {
                appData.files.dataSource.read();
            },
        },

        video: kendo.observable({
            source: undefined,
            playing: false,
        }),
    });
</script>

<script>
    kendo.bind($("#video"), appData.video);

    function removeVideo(event, id) {
        event.preventDefault();
        
        $.ajax({
            async: false,
            url: "<%= url_for('/v1/video/delete')->to_abs %>",
            dataType: "json",
            contentType: "application/json",
            method: "POST",
            data: kendo.stringify({ video_id: id}),
            success: function (result) {
                if (result.success) {
                    $("#videoList").data("kendoMobileListView").dataSource.read();
                }
                else {
                    alert(result.message);
                }
            }
        });
    }

    var app = new kendo.mobile.Application(document.body, {
        skin: "flat",
        init: function() {
            $("#videoList").kendoMobileListView({
                dataSource: appData.videos.dataSource,
                template: function(data) {
                    var template = kendo.template('<a data-role="button" data-icon="sounds"></a> #: name # <a data-role="detailbutton" onclick="removeVideo(event, #:video_id#);" data-icon="trash" class="km-style-error"></a>');
                    var data = { name: data.video_name, video_id: data.video_id };

                    return template(data);
                },
                style: "inset",
                click: function(e) {
                    if ($(e.target).hasClass("km-trash")) {
                        return;
                    }
                    // appData.video.set("source", "/video/" + e.dataItem.video_id);
                    $('#video').html(
                        '<source type="video/mp4" src="/video/' + e.dataItem.video_id +  '">' +
                        '<source type="video/ogg" src="/video/' + e.dataItem.video_id +  '">' +
                        'Your browser does not support the video tag.'
                    );

                    appData.video.set("playing", true);
                }
            });

            $("#filePager").kendoPager({
                dataSource: appData.files.dataSource,
                previousNext: true,
                input: false,
                numeric: true
            });

            $("#fileList").kendoMobileListView({
                dataSource: appData.files.dataSource,
                filterable: {
                    ignoreCase: true,
                    field: "value"
                },
                headerTemplate: "#: value #",
                template: "#: entry #",
                autoBind: false,
                click: function(e) {
                    if ("." === e.entry) {
                        return;
                    }

                    $.ajax({
                        async: false,
                        url: "<%= url_for('/v1/entry')->to_abs %>",
                        dataType: "json",
                        contentType: "application/json",
                        method: "POST",
                        data: kendo.stringify({ action: "select", entry: e.dataItem.entry }),
                        success: function (result) {
                            if (result.success && result.file) {
                                var hope = function() {
                                    // Need moar error checking
                                    $("#fileList").data("kendoMobileListView").dataSource.page(1);
                                    $("#fileList").data("kendoMobileListView").dataSource.read().then(function() {
                                        $("#videoList").data("kendoMobileListView").dataSource.read().then(function() {
                                            $("#file-drawer").data("kendoMobileDrawer").hide();
                                        });
                                    });
                                };
                                setTimeout(hope, 1);
                            }
                            else if (result.success && result.directory) {
                                var hope = function() {
                                    // Need moar error checking
                                    $("#fileList").data("kendoMobileListView").dataSource.page(1);
                                    $("#fileList").data("kendoMobileListView").dataSource.read();
                                };
                                setTimeout(hope, 1);
                            }
                            else {
                                alert(result.message);
                            }
                        }
                    });
                }
            });
        },
    });
</script>
</body>
</html>
