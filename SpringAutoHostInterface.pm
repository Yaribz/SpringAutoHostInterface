# Object-oriented Perl module implementing a callback-based interface to
# communicate with SpringRTS engine through autohost interface.
#
# Copyright (C) 2008-2013  Yann Riou <yaribzh@gmail.com>
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.
#

package SpringAutoHostInterface;

use strict;

use IO::Socket::INET;
use Storable "dclone";

use SimpleLog;

# Internal data ###############################################################

my $moduleVersion='0.10';

my %commandCodes = (
  0 => 'SERVER_STARTED',
  1 => 'SERVER_QUIT',
  2 => 'SERVER_STARTPLAYING',
  3 => 'SERVER_GAMEOVER',
  4 => 'SERVER_MESSAGE',
  5 => 'SERVER_WARNING',
  10 => 'PLAYER_JOINED',
  11 => 'PLAYER_LEFT',
  12 => 'PLAYER_READY',
  13 => 'PLAYER_CHAT',
  14 => 'PLAYER_DEFEATED',
  20 => 'GAME_LUAMSG',
  60 => 'GAME_TEAMSTAT'
);

my %destinations = (
  125 => '',
  126 => 'spectators',
  127 => 'allies',
  252 => 'allies',
  253 => 'spectators',
  254 => ''
);

my %commandHandlers = (
  SERVER_STARTED => \&serverStartedHandler,
  SERVER_QUIT => \&serverQuitHandler,
  SERVER_STARTPLAYING => \&serverStartPlayingHandler,
  SERVER_GAMEOVER => \&serverGameOverHandler,
  SERVER_MESSAGE => \&serverMessageHandler,
  PLAYER_JOINED => \&playerJoinedHandler,
  PLAYER_LEFT => \&playerLeftHandler,
  PLAYER_READY => \&playerReadyHandler,
  PLAYER_DEFEATED => \&playerDefeatedHandler
);

# Constructor #################################################################

sub new {
  my ($objectOrClass,%params) = @_;
  my $class = ref($objectOrClass) || $objectOrClass;
  my $p_conf = {
    autoHostPort => 8454,
    simpleLog => undef,
    warnForUnhandledMessages => 1
  };
  foreach my $param (keys %params) {
    if(grep(/^$param$/,(keys %{$p_conf}))) {
      $p_conf->{$param}=$params{$param};
    }else{
      if(! (defined $p_conf->{simpleLog})) {
        $p_conf->{simpleLog}=SimpleLog->new(prefix => "[SpringAutoHostInterface] ");
      }
      $p_conf->{simpleLog}->log("Ignoring invalid constructor parameter ($param)",2)
    }
  }
  if(! (defined $p_conf->{simpleLog})) {
    $p_conf->{simpleLog}=SimpleLog->new(prefix => "[SpringAutoHostInterface] ");
  }

  # Server states:
  #   0 -> not running
  #   1 -> server started
  #   2 -> game started
  #   3 -> game over
  #
  # Player disconnect causes:
  #   -2 -> loading
  #   -1 -> connected
  #   0 -> connection lost
  #   1 -> player left
  #   2 -> kicked
  #
  # Player ready states:
  #   0 -> not ready
  #   1 -> ready
  #   2 -> unknown

  my $self = {
    conf => $p_conf,
    autoHostSock => undef,
    state => 0,
    gameId => '',
    demoName => '',
    players => {},
    callbacks => {},
    preCallbacks => {},
    connectingPlayer => { name => "", version => "", address => "" }
  };

  bless ($self, $class);
  return $self;
}

# Accessors ###################################################################

sub getState {
  my $self = shift;
  return $self->{state};
}

sub getPlayers {
  my $self = shift;
  return dclone($self->{players});
}

sub getPlayersByNames {
  my $self = shift;
  my %playersByNames;
  foreach my $playerNb (keys %{$self->{players}}) {
    $playersByNames{$self->{players}->{$playerNb}->{name}}=dclone($self->{players}->{$playerNb});
  }
  return \%playersByNames;
}

sub getVersion {
  return $moduleVersion;
}

sub getPlayer {
  my ($self,$name)=@_;
  foreach my $playerNb (keys %{$self->{players}}) {
    return $self->{players}->{$playerNb} if($self->{players}->{$playerNb}->{name} eq $name);
  }
  return {};
}

# Debugging method ############################################################

sub dumpState {
  my $self=shift;
  my %conf=%{$self->{conf}};
  my $sl=$conf{simpleLog};
  $sl->log("-------------------------- DUMPING STATE ----------------------------",5);
  $sl->log("State:$self->{state}",5);
  $sl->log("Players:",5);
  foreach my $pId (keys %{$self->{players}}) {
    my $pHash=$self->{players}->{$pId};
    $sl->log("  $pId: name=$pHash->{name},ready=$pHash->{ready},lost=$pHash->{lost},disconnectCause=$pHash->{disconnectCause},version=$pHash->{version}",5);
  }
  $sl->log("--------------------------- END OF DUMP -----------------------------",5);
}

# Marshallers/unmarshallers ###################################################

sub unmarshallCommands {
  my ($self,$marshalled)=@_;
  my %conf=%{$self->{conf}};
  my $sl=$conf{simpleLog};
  my @bytes=unpack("C*",$marshalled);
  return $self->unmarshallBytes(\@bytes);
}

sub unmarshallBytes {
  my ($self,$p_bytes)=@_;
  my %conf=%{$self->{conf}};
  my $sl=$conf{simpleLog};
  return [] unless(@{$p_bytes});
  my $commandCode=shift(@{$p_bytes});
  if(exists $commandCodes{$commandCode}) {
    my $commandName=$commandCodes{$commandCode};
    my @command=($commandName);
    if($commandName eq "PLAYER_JOINED") {
      my $playerNb=shift(@{$p_bytes});
      if(! (defined $playerNb)) {
        $sl->log("Unable to unmarshall PLAYER_JOINED command (incomplete command)",1);
        return [];
      }
      push(@command,$playerNb);
      push(@command,$self->unmarshallStringFromBytes($p_bytes));
    }elsif($commandName eq "PLAYER_LEFT") {
      my $playerNb=shift(@{$p_bytes});
      if(! (defined $playerNb)) {
        $sl->log("Unable to unmarshall PLAYER_LEFT command (incomplete command)",1);
        return [];
      }
      my $reason=shift(@{$p_bytes});
      if(! (defined $reason)) {
        $sl->log("Unable to unmarshall PLAYER_LEFT command (incomplete command)",1);
        return [];
      }
      push(@command,$playerNb,$reason);
    }elsif($commandName eq "PLAYER_READY") {
      my $playerNb=shift(@{$p_bytes});
      if(! (defined $playerNb)) {
        $sl->log("Unable to unmarshall PLAYER_READY command (incomplete command)",1);
        return [];
      }
      my $state=shift(@{$p_bytes});
      if(! (defined $state)) {
        $sl->log("Unable to unmarshall PLAYER_READY command (incomplete command)",1);
        return [];
      }
      push(@command,$playerNb,$state);
    }elsif($commandName eq "PLAYER_CHAT") {
      my $playerNb=shift(@{$p_bytes});
      if(! (defined $playerNb)) {
        $sl->log("Unable to unmarshall PLAYER_CHAT command (incomplete command)",1);
        return [];
      }
      push(@command,$playerNb);
      my $dest=shift(@{$p_bytes});
      $dest="" unless(defined $dest);
      if(exists $destinations{$dest}) {
        $dest=$destinations{$dest};
      }elsif(exists $self->{players}->{$dest}) {
        $dest=$self->{players}->{$dest}->{name};
      }
      push(@command,$dest);
      push(@command,$self->unmarshallStringFromBytes($p_bytes));
    }elsif($commandName eq "PLAYER_DEFEATED") {
      my $playerNb=shift(@{$p_bytes});
      if(! (defined $playerNb)) {
        $sl->log("Unable to unmarshall PLAYER_DEFEATED command (incomplete command)",1);
        return [];
      }
      push(@command,$playerNb);
    }elsif($commandName eq "SERVER_MESSAGE" || $commandName eq "SERVER_WARNING") {
      push(@command,$self->unmarshallStringFromBytes($p_bytes));
    }elsif($commandName eq "GAME_LUAMSG") {
      # Drop extra characters (bug workaround ?)
      for my $i (0..2) {
        shift @{$p_bytes};
      }
      my $playerNb=shift(@{$p_bytes});
      my $script1=shift(@{$p_bytes});
      my $script2=shift(@{$p_bytes});
      my $mode=shift(@{$p_bytes});
      if(! (defined $mode)) {
        $sl->log("Unable to unmarshall GAME_LUAMSG command (incomplete command)",1);
        return [];
      }
      my $script=$script2 * 256 + $script1;
      $mode=chr($mode);
      push(@command,$playerNb,$script,$mode,pack("C*",@{$p_bytes}));
      $p_bytes=[];
    }elsif($commandName eq 'GAME_TEAMSTAT') {
      my $teamNb=shift(@{$p_bytes});
      if(! (defined $teamNb)) {
        $sl->log("Unable to unmarshall GAME_TEAMSTAT command (incomplete command)",1);
        return [];
      }
      push(@command,$teamNb,unpack("If[12]I[7]",pack("C*",@{$p_bytes})));
      $p_bytes=[];
    }elsif($commandName eq 'SERVER_STARTPLAYING') {
      my $hasParams;
      for my $i (1..4) {
        $hasParams=shift(@{$p_bytes});
      }
      if(defined $hasParams) {
        my $gameId='';
        for my $i (1..16) {
          $gameId.=sprintf('%02x',shift(@{$p_bytes}));
        }
        my $demoName=$self->unmarshallStringFromBytes($p_bytes);
        push(@command,$gameId,$demoName);
      }
    }elsif($commandName eq 'SERVER_GAMEOVER') {
      my $msgSize=shift(@{$p_bytes});
      my $playerNb=shift(@{$p_bytes});
      my @winningAllyTeams;
      for my $allyTeamIndex (1..($msgSize-3)) {
        push(@winningAllyTeams,shift(@{$p_bytes}));
      }
      push(@command,$msgSize,$playerNb,@winningAllyTeams);
    }
    my $p_otherCommands=$self->unmarshallBytes($p_bytes);
    return [\@command,@{$p_otherCommands}];
  }else{
    $sl->log("Unknown command code \"$commandCode\"",1);
    return [];
  }
}

sub unmarshallStringFromBytes {
  my ($self,$p_bytes)=@_;
  my %conf=%{$self->{conf}};
  my $sl=$conf{simpleLog};
  my $string="";
  while(@{$p_bytes}) {
    my $charCode=shift(@{$p_bytes});
    if($charCode > 31) {
      $string.=chr($charCode);
    }else{
      $string.="_";
      $sl->log("Control character #$charCode encountered while parsing a string received from spring server",2);
    }
  }
  return $string;
}

# Business functions ##########################################################

sub addCallbacks {
  my ($self,$p_callbacks,$nbCalls,$priority)=@_;
  $priority=caller() unless(defined $priority);
  $nbCalls=0 unless(defined $nbCalls);
  my %callbacks=%{$p_callbacks};
  foreach my $command (keys %callbacks) {
    $self->{callbacks}->{$command}={} unless(exists $self->{callbacks}->{$command});
    if(exists $self->{callbacks}->{$command}->{$priority}) {
      $self->{conf}->{simpleLog}->log("Replacing an existing $command callback for priority \"$priority\"",2);
    }
    $self->{callbacks}->{$command}->{$priority}=[$callbacks{$command},$nbCalls];
  }
}

sub removeCallbacks {
  my ($self,$p_commands,$priority)=@_;
  $priority=caller() unless(defined $priority);
  my @commands=@{$p_commands};
  foreach my $command (@commands) {
    if(exists $self->{callbacks}->{$command}) {
      delete $self->{callbacks}->{$command}->{$priority};
      delete $self->{callbacks}->{$command} unless(%{$self->{callbacks}->{$command}});
    }
  }
}

sub addPreCallbacks {
  my ($self,$p_preCallbacks,$priority)=@_;
  $priority=caller() unless(defined $priority);
  foreach my $command (keys %{$p_preCallbacks}) {
    $self->{preCallbacks}->{$command}={} unless(exists $self->{preCallbacks}->{$command});
    if(exists $self->{preCallbacks}->{$command}->{$priority}) {
      $self->{conf}->{simpleLog}->log("Replacing an existing $command pre-callback for priority \"$priority\"",2);
    }
    $self->{preCallbacks}->{$command}->{$priority}=$p_preCallbacks->{$command};
  }
}

sub removePreCallbacks {
  my ($self,$p_commands,$priority)=@_;
  $priority=caller() unless(defined $priority);
  foreach my $command (@{$p_commands}) {
    if(exists $self->{preCallbacks}->{$command}) {
      delete $self->{preCallbacks}->{$command}->{$priority};
      delete $self->{preCallbacks}->{$command} unless(%{$self->{preCallbacks}->{$command}});
    }
  }
}

sub open {
  my $self = shift;
  my %conf=%{$self->{conf}};
  my $sl=$conf{simpleLog};
  $sl->log("Listening on AutoHost port (127.0.0.1:$conf{autoHostPort})",3);
  if((defined $self->{autoHostSock}) && $self->{autoHostSock}) {
    $sl->log("Could not start listening on AutoHost port (already listening)!",2);
    return $self->{autoHostSock};
  }
  $self->{autoHostSock} = new IO::Socket::INET(LocalHost => "127.0.0.1",
                                               LocalPort => $conf{autoHostPort},
                                               Proto => 'udp',
                                               Blocking => 0);
  if(! $self->{autoHostSock}) {
    $sl->log("Unable to listen on 127.0.0.1:$conf{autoHostPort} ($@)",0);
    undef $self->{autoHostSock};
    return 0;
  }
  return $self->{autoHostSock};
}

sub close {
  my $self = shift;
  my %conf=%{$self->{conf}};
  my $sl=$conf{simpleLog};
  $sl->log("Closing AutoHost interface",3);
  if(! ((defined $self->{autoHostSock}) && $self->{autoHostSock})) {
    $sl->log("Unable to close AutoHost interface (already closed)!",2);
  }else{
    close($self->{autoHostSock});
    undef $self->{autoHostSock};
  }
  $self->{state}=0;
  $self->{players}={};
  $self->{gameId}='';
  $self->{demoName}='';
}

sub sendChatMessage {
  my ($self,$message) = @_;
  my %conf=%{$self->{conf}};
  my $sl=$conf{simpleLog};
  if(! ((defined $self->{autoHostSock}) && $self->{autoHostSock})) {
    $sl->log("Unable to send chat message (AutoHost interface not opened)",1);
    return 0;
  }
  if(! $self->{state}) {
    $sl->log("Unable to send chat message (server not connected)",1);
    return 0;
  }
  my $autoHostSock=$self->{autoHostSock};
  $autoHostSock->send("$message");
  $sl->log("Sent on AutoHost interface: \"$message\"",5);
  return 1;
}

sub prioSort {
  if($a =~ /^\d+$/ && $b =~ /^\d+$/) {
    return $a <=> $b;
  }
  if($a =~ /^\d+$/) {
    return $a <=> 1000;
  }
  if($b =~ /^\d+$/) {
    return 1000 <=> $b;
  }
  return 0;
}

sub receiveCommand {
  my $self=shift;
  my %conf=%{$self->{conf}};
  my $sl=$conf{simpleLog};
  if(! ((defined $self->{autoHostSock}) && $self->{autoHostSock})) {
    $sl->log("Unable to receive command (AutoHost interface not opened)",1);
    return 0;
  }
  my $autoHostSock=$self->{autoHostSock};
  my $recvBuf;
  $autoHostSock->recv($recvBuf,4096);
  $recvBuf="" unless(defined $recvBuf);
  if($recvBuf eq "") {
    $sl->log("Empty message received on AutoHost interface",2);
    return 0;
  }
  $sl->log("Received from Game server: \"$recvBuf\"",5);
  my $p_commands=$self->unmarshallCommands($recvBuf);
  my $rc=1;
  for my $cIndex (0..$#{$p_commands}) {
    my $p_command=$p_commands->[$cIndex];
    $sl->log(" --> unmarshalled as:\"".join(",",@{$p_command})."\"",5);
    my $commandName=$p_command->[0];
    my $processed=0;

    if(exists($self->{preCallbacks}->{'_ALL_'})) {
      foreach my $prio (sort prioSort (keys %{$self->{preCallbacks}->{'_ALL_'}})) {
        $processed=1;
        my $p_preCallback=$self->{preCallbacks}->{'_ALL_'}->{$prio};
        &{$p_preCallback}(@{$p_command}) if($p_preCallback);
      }
    }
    if(exists($self->{preCallbacks}->{$commandName})) {
      foreach my $prio (sort prioSort (keys %{$self->{preCallbacks}->{$commandName}})) {
        $processed=1;
        my $p_preCallback=$self->{preCallbacks}->{$commandName}->{$prio};
        &{$p_preCallback}(@{$p_command}) if($p_preCallback);
      }
    }

    if(exists($commandHandlers{$commandName})) {
      $processed=1;
      $rc = &{$commandHandlers{$commandName}}($self,@{$p_command}) && $rc if($commandHandlers{$commandName});
    }

    if(exists($self->{callbacks}->{$commandName})) {
      foreach my $prio (sort prioSort (keys %{$self->{callbacks}->{$commandName}})) {
        my ($callback,$nbCalls)=@{$self->{callbacks}->{$commandName}->{$prio}};
        $processed=1;
        if($nbCalls == 1) {
          delete $self->{callbacks}->{$commandName}->{$prio};
        }elsif($nbCalls > 1) {
          $nbCalls-=1;
          $self->{callbacks}->{$commandName}->{$prio}=[$callback,$nbCalls];
        }
        $rc = &{$callback}(@{$p_command}) && $rc if($callback);
      }
      delete $self->{callbacks}->{$commandName} unless(%{$self->{callbacks}->{$commandName}});
    }

    if(! $processed && $conf{warnForUnhandledMessages}) {
      $sl->log("Unexpected/unhandled command received: \"$recvBuf\"",2);
      $rc=0;
    }
  }
  return $rc;
};

sub checkGameOver {
  my $self=shift;
  my ($nbOver,$nbInProgress)=(0,0);
  foreach my $playerNb (keys %{$self->{players}}) {
    if(defined $self->{players}->{$playerNb}->{winningAllyTeams}) {
      $nbOver++;
    }elsif($self->{players}->{$playerNb}->{disconnectCause} < 0) {
      $nbInProgress++;
    }
  }
  $self->{state}=3 if($nbOver > $nbInProgress);
}

# Internal handlers and hooks #################################################

sub serverStartedHandler {
  my $self=shift;
  $self->{state}=1;
  $self->{gameId}='';
  $self->{demoName}='';
  return 1;
}

sub serverQuitHandler {
  my $self=shift;
  $self->{state}=0;
  $self->{players}={};
  return 1;
}

sub serverStartPlayingHandler {
  my ($self,undef,$gameId,$demoName)=@_;
  $self->{state}=2;
  $self->{gameId}=$gameId if(defined $gameId);
  $self->{demoName}=$demoName if(defined $demoName);
  return 1;
}

sub serverGameOverHandler {
  my ($self,undef,undef,$playerNb,@winningAllyTeams)=@_;
  my %conf=%{$self->{conf}};
  my $sl=$conf{simpleLog};
  if(! exists $self->{players}->{$playerNb}) {
    $sl->log("Ignoring SERVER_GAMEOVER message on AutoHost interface (unknown player number $playerNb)",1);
  }
  $self->{players}->{$playerNb}->{winningAllyTeams}=\@winningAllyTeams;
  $self->checkGameOver();
  return 1;
}

sub serverMessageHandler {
  my ($self,undef,$msg)=@_;
  my %conf=%{$self->{conf}};
  my $sl=$conf{simpleLog};
  if($msg =~ /^Connection attempt from ([^\ ]+)$/) {
    $self->{connectingPlayer}->{name}=$1;
    $self->{connectingPlayer}->{version}="";
    $self->{connectingPlayer}->{address}="";
  }elsif($msg =~ /^ -> Version: (.*)$/) {
    $self->{connectingPlayer}->{version}=$1;
  }elsif($msg =~ /^ -> Address: (.*)$/) {
    $self->{connectingPlayer}->{address}=$1;
  }elsif($msg =~ /^ -> Connection established \(given id (\d+)\)$/) {
    my $playerNb=$1;
    if(exists $self->{players}->{$playerNb}) {
      if($self->{connectingPlayer}->{name} ne $self->{players}->{$playerNb}->{name}) {
        $sl->log("Received a SERVER_MESSAGE command saying player \#$playerNb was $self->{connectingPlayer}->{name}, whereas PLAYER_JOINED said it was $self->{players}->{$playerNb}->{name}",1);
      }else{
        $self->{players}->{$playerNb}->{version}=$self->{connectingPlayer}->{version};
        $self->{players}->{$playerNb}->{address}=$self->{connectingPlayer}->{address};
        $self->{players}->{$playerNb}->{disconnectCause}=-2;
      }
    }else{
      $self->{players}->{$playerNb} = { name => $self->{connectingPlayer}->{name},
                                        disconnectCause => -2,
                                        ready => 2,
                                        lost => 0,
                                        version => $self->{connectingPlayer}->{version},
                                        address => $self->{connectingPlayer}->{address},
                                        winningAllyTeams => undef,
                                        playerNb => $playerNb };
    }
    $self->{connectingPlayer}->{name}="";
    $self->{connectingPlayer}->{version}="";
    $self->{connectingPlayer}->{address}="";
  }
  return 1;
}

sub playerJoinedHandler {
  my ($self,undef,$playerNb,$name)=@_;
  my %conf=%{$self->{conf}};
  my $sl=$conf{simpleLog};
  if(exists $self->{players}->{$playerNb}) {
    if($name ne $self->{players}->{$playerNb}->{name}) {
      $sl->log("Received a PLAYER_JOINED command saying player \#$playerNb was $name, whereas SERVER_MESSAGE said it was $self->{players}->{$playerNb}->{name}",1);
    }else{
      $self->{players}->{$playerNb}->{disconnectCause}=-1;
    }
  }else{
    $self->{players}->{$playerNb} = { name => $name,
                                      disconnectCause => -1,
                                      ready => 2,
                                      lost => 0,
                                      version => '',
                                      address => '',
                                      winningAllyTeams => undef,
                                      playerNb => $playerNb };
  }
  return 1;
}

sub playerLeftHandler {
  my ($self,undef,$playerNb,$reason)=@_;
  my %conf=%{$self->{conf}};
  my $sl=$conf{simpleLog};
  if(exists $self->{players}->{$playerNb}) {
    $self->{players}->{$playerNb}->{disconnectCause}=$reason;
    $self->checkGameOver();
  }else{
    $sl->log("Ignoring PLAYER_LEFT message on AutoHost interface (unknown player number $playerNb)",1);
  }
  return 1;
}

sub playerReadyHandler {
  my ($self,undef,$playerNb,$readyState)=@_;
  my %conf=%{$self->{conf}};
  my $sl=$conf{simpleLog};
  if(exists $self->{players}->{$playerNb}) {
    $self->{players}->{$playerNb}->{ready}=$readyState if($readyState != 2);
  }else{
    $sl->log("Ignoring PLAYER_READY message on AutoHost interface (unknown player number $playerNb)",1);
  }
  return 1;
}

sub playerDefeatedHandler {
  my ($self,undef,$playerNb)=@_;
  my %conf=%{$self->{conf}};
  my $sl=$conf{simpleLog};
  if(exists $self->{players}->{$playerNb}) {
    $self->{players}->{$playerNb}->{lost}=1;
  }else{
    $sl->log("Ignoring PLAYER_DEFEATED message on AutoHost interface (unknown player number $playerNb)",1);
  }
  return 1;
}

1;
