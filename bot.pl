#!/usr/bin/env perl
use 5.016;
use strict;
use warnings;
use utf8;

use AnyEvent;
use AnyEvent::IRC::Client;

use lib '.';
use Game;

my $c = AE::cv;
my $irc = AnyEvent::IRC::Client->new;

$irc->reg_cb(connect => sub {
    my ($irc, $err) = @_;
    if (defined $err) {
        warn "connect error: $err\n";
        return;
    }
});
$irc->reg_cb(disconnect => sub { say "Disconnected!"; $c->broadcast });


$irc->reg_cb(publicmsg => sub { 
    my ($irc, $channel, $irc_msg) = @_;

    my $msg = $irc_msg->{params}[-1];
    my $pre = substr $msg, 0, 1, "";
    return unless $pre eq '!' && $msg ne "";

    my ($who) = $irc_msg->{prefix} =~ /^([^!]+)/;
    $irc->event('command', $who, $msg, $channel);
});


use Text::Abbrev;
my $abbreviations = abbrev qw(join ready play choose hand scores kick);

my $game;
$irc->reg_cb(command => sub { 
    my ($irc, $who, $what, $where) = @_;
    $what = lc $what;

    my ($cmd, @params) = split ' ', $what;
    $cmd = $abbreviations->{$cmd} // $cmd;  

    if ($cmd eq 'game'){
        unless (defined $game && $game->playing){
            my $pcount = $params[0] 
                if $params[0] && $params[0] =~ /^\d+$/ && $params[0] > 2;
            $game = Game->new(
                irc => $irc, 
                channel => $where, 
                min_players => $pcount || 4
            );
        }
        return;
    }

    if (defined $game && $game->playing) {
        $game->join_player($who) if $cmd eq 'join';
        $game->ready($who)       if $cmd eq 'ready';
        $game->show_hand($who)   if $cmd eq 'hand';
        $game->show_scores($who) if $cmd eq 'scores';
        $game->unjoin($who)      if $cmd eq 'quit';

        if ($cmd eq 'kick' && @params > 0){
            $game->kick($who, $params[0]);
        }

        if ($cmd eq 'play' && ! grep { /\D/ } @params){
            $game->submit_cards($who, @params);
        }

        if ($cmd eq 'choose' && $params[0] =~ /^\d+$/){
            $game->choose_winner($who, $params[0]);
        }

    }
});

$irc->reg_cb(channel_change => sub {
    return unless defined $game;
    my ($msg, $channel, $old_nick, $new_nick, $is_myself) = @_;
    $game->rename_player($old_nick, $new_nick);
});

$irc->reg_cb(channel_remove => sub {
    return unless defined $game;
    my ($msg, $channel, @nicks) = @_;
    $game->unjoin($_) for @nicks;
});



$irc->connect("irc.7chan.org", 6667, { nick => 'cahbot' });

$irc->send_srv(NS => 'identify madl1bz.');
#$irc->send_srv(JOIN => '#linux');


use AnyEvent::ReadLine::Gnu;

my $rl; $rl = AnyEvent::ReadLine::Gnu->new( prompt => "irc> ", on_line => sub {
    my $what = $_[0];
    $irc->send_raw($what);
});

$c->wait;
