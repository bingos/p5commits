use 5.010;
use strict;
use warnings;
use Email::Simple;
use POE::Kernel { loop => 'POE::XS::Loop::Poll' };
use if $^O eq 'linux', 'POE::Kernel'=> { loop => 'POE::XS::Loop::EPoll' };
use unless $^O eq 'linux', 'POE::Kernel' => { loop => 'POE::XS::Loop::Poll' };
use POE qw(Component::IRC);
use POE::Component::IRC::Common qw( :ALL );
use POE::Component::IRC::Plugin::Connector;
use POE::Component::Client::NNTP::Tail;
use POE::Component::Client::HTTP;
use IRC::Utils qw[uc_irc decode_irc parse_user];
use HTTP::Request::Common qw[GET];

use constant NNTPSERVER => 'nntp.perl.org';
use constant NNTPGROUP  => 'perl.perl5.changes';
use constant BASEURL    => 'http://www.nntp.perl.org/group/perl.perl5.changes';
use constant BASEURL2   => 'http://perl5.git.perl.org/perl.git/commit/';
use constant RTBROWSE   => 'http://rt.perl.org/rt3/Public/Bug/Display.html?id=';

use constant NICKNAME   => 'p5commits';
use constant IRCSERVER  => '217.168.150.167';
use constant IRCPORT    => '6667';
use constant IRCUSER    => 'p5p';
use constant IRCNAME    => 'p5commits bot <see BinGOs>';
use constant CHANNEL    => '#p5p';

my $current_id = 0;
my %active_ids;

sub allocate_id {
  while (1) {
    last unless exists $active_ids{ ++$current_id };
  }
  return $active_ids{$current_id} = $current_id;
}

sub free_id {
  my $id = shift;
  delete $active_ids{$id};
}

my $answer_re = qr/
        (?: \b(perl|bug|rt) \s+ \# (\d+)\b )
        |
        (?: \b(change|commit) \s+
            \#? ([0-9a-fA-F]+)\b (?!\s+ \w+ \s+ (?:into|to|in)) )
        |
        (?: (\#) ([0-9a-fA-F]+)\b )
    /xi;

my $ignores = join '|', map { quotemeta( uc_irc( $_ ) ) } qw( purl NL-PM dipsy clunker3 );
my $ignore_re = qr/^($ignores)$/;

$|=1;

POE::Component::Client::HTTP->spawn(
  Agent => 'p5commits/1.00',
  Alias => 'ua',
  FollowRedirects => 5,
);

my $irc = POE::Component::IRC->spawn( debug => 0 );

POE::Component::Client::NNTP::Tail->spawn(
   NNTPServer  => NNTPSERVER,
   Group       => NNTPGROUP,
);

POE::Session->create(
    package_states => [
	    'main' => [ qw(_start irc_001 irc_join irc_public _header _article _response) ],
    ],
    options => { trace => 0 },
);

$poe_kernel->run();
exit 0;

sub _start {
  my ($kernel, $heap, $session) = @_[KERNEL, HEAP, SESSION];
  $kernel->post( NNTPGROUP, 'register', '_header' );
  $irc->yield( register => 'all' );
  $irc->plugin_add( 'Connector', POE::Component::IRC::Plugin::Connector->new() );
  $irc->yield( connect => {
    Nick     => NICKNAME,
    Server   => IRCSERVER,
    Port     => IRCPORT,
    Username => IRCUSER,
    Ircname  => IRCNAME,
  } );
  return;
}

sub irc_001 {
  $irc->yield( 'join', CHANNEL );
  return;
}

sub irc_join {
  my ($heap,$nickhost,$channel) = @_[HEAP,ARG0,ARG1];
  return;
}

sub irc_public {
  my ($kernel,$heap,$who,$where,$what) = @_[KERNEL,HEAP,ARG0..ARG2];
  my $nick = ( split /!/, $who )[0];
  {
    ( my $foo = $nick ) =~ s/_*$//;
    $foo = uc_irc( $foo );
    return if $foo =~ /$ignore_re/;
  }
  {
    my $decode = decode_irc( $what );
    while ( $decode =~ /$answer_re/g ) {
        my $what = $1 || $3 || $5;
        my $numb = $2 || $4 || $6;

        # skip "requests" for changes before 1000 that were not
        # directly addressed to the bot (or /msg)
        if ( $what =~ /change|commit|#/i &&
             $numb =~ /^[0-9]+$/ && $numb <= 1000 ) {
            next;
        }

        my $ua = $what =~ /change|commit|#/i ? 'perlbrowse' : 'rtbrowse';

        {
          my $id = allocate_id();
          my $url = ( $ua eq 'perlbrowse' ? BASEURL2 : RTBROWSE ) . $numb;
          my $req = GET $url;
          $kernel->post(
            'ua',
            'request',
            '_response',
            $req,
            $id,
          );
          $heap->{requests}->{ $id } = [ $numb, $ua, $where ];
        }
        #my $msg = $self->$ua( $numb );
        #$msg and $self->reply( $args, $msg );

        #$msg and $self->log( "$ua: $msg" );

    }
  }
  return;
}

sub _response {
  my ($heap,$request_packet,$response_packet) = @_[HEAP,ARG0,ARG1];
  my ($numb,$type,$where);
  {
    my $id = $request_packet->[1];
    my $data = delete $heap->{requests}->{ $id };
    free_id( $id );
    ($numb,$type,$where) = @{ $data };
  }
  my $resp = $response_packet->[0];
  return unless $resp->is_success;
  my $msg;
  if ( $type eq 'perlbrowse' ) {
    my ($porter) = $resp->content =~ m|author</td><td>(.+) &lt;|;
    my ($subj)   =
        $resp->content =~ m|<a class="title" href="/perl\.git/commit.+?">(.+?)</a>|;
    $msg = $porter
        ? "Commit \#$numb($porter): $subj " . BASEURL2 . $numb
        : "Commit \#$numb not found on perlbrowse";
  }
  else {
    return if $resp->content !~ m{Queue:</td>\n.+perl5};
    require HTML::HeadParser;
    my $p = HTML::HeadParser->new;
    $p->parse($resp->content);
    $msg = $p->header('Title') || '';
    $msg =~ s/^#/rt #/;
    $msg .= ' ' . RTBROWSE . $numb;
  }
  $irc->yield( 'privmsg', $where->[0], $msg ) if $msg;
  return;
}

sub _header {
  my ($kernel,$id,$article) = @_[KERNEL,ARG0,ARG1];
  my $post = Email::Simple->new( join("\n", @$article) );
  return unless $post->header('Subject') =~ /^\Q[perl.git]/i;
  $kernel->post( $_[SENDER], 'get_article', $id, '_article' );
  return;
}

sub _article {
  my ($kernel,$id,$article) = @_[KERNEL,ARG0,ARG1];
  my $post = Email::Simple->new( join("\n", @$article) );
  return unless $post->header('Subject') =~ /^\Q[perl.git]/i;
  (my $subject = $post->header( 'Subject' )) =~ s/\015?\012//g;
  my ($git_describe) = $subject =~ m!(v5.+)$!;

  my $body = $post->body;
  my ($branch,$action) = $body =~ m|In perl.git, the branch ([^ ]+) has been ([^ ]+)|;
  $branch ||= 'nobranch';

  (my $porter = $post->header( 'From' )) =~ s/\015?\012//g;
  $porter ||= '("unknown")';
  my ($pname) = $porter =~ /\("(.+)"\)/;

  my $msg = "$pname pushed to $branch ($git_describe):";
  if ( $action eq 'deleted' ) {
    say $action;
    $msg .= " $action";
    say $msg;
    $irc->yield( 'ctcp', CHANNEL, "ACTION $msg" );
    return;
  }
  while ( $body =~ /\015?\012commit\s+([0-9a-f]{8})/g ) {
      my $sha1 = $1;

      pos( $body ) = index( $body, 'Author:', pos( $body ) );
      my ($author) = $body =~ m/\GAuthor:\s+(.+) <.+>\015?\012/;

      pos( $body ) = index( $body, 'Date', pos( $body ) );
      my ($commitmsg) = $body =~ m/\GDate:.+\s+(.+)/;
      $commitmsg ||= 'no commit message found.';

      my $url = BASEURL2 . $sha1;
      $msg .= " $author: $commitmsg; $url";
  }
  say $msg;
  $irc->yield( 'ctcp', CHANNEL, "ACTION $msg" );
  return;
}

# We registered for all events, this will produce some debug info.
sub _default {
   my ($event, $args) = @_[ARG0 .. $#_];
   my @output = ( "$event: " );

   for my $arg (@$args) {
      if ( ref $arg eq 'ARRAY' ) {
         push( @output, '[' . join(', ', @$arg ) . ']' );
      }
      else {
         push ( @output, "'$arg'" );
      }
   }
   print join ' ', @output, "\n";
   return 0;
}
