#!/usr/bin/env perl
use 5.016;
use strict;
use warnings;
use utf8;

use Moops;
use AnyEvent;
use AnyEvent::ReadLine::Gnu;

use lib '.';
use Game;

class TermGame extends Game {
    has conduit => (is => 'ro', isa => 'AnyEvent::ReadLine::Gnu');
    method say (Str $string) {
        $self->conduit->print("$string\n");
    }

    method say_to (Str $name, Str $string) {
        $self->conduit->print("$name: $string\n");
    }

    method act (Str $string) {
        $self->conduit->print("*$string*\n");
    }
}

use Text::Abbrev;
my $abbreviations = abbrev qw(join ready play choose hand scores);

my $game;
my $rl; $rl = AnyEvent::ReadLine::Gnu->new( prompt => "> ", on_line => sub {
    my $what = lc $_[0];

    if ($what eq 'game') {
        $game = TermGame->new(conduit => $rl);
        return;
    }

    my ($cmd, @params) = split ' ', $what;
    $cmd = $abbreviations->{$cmd} // $cmd;

    if (defined $game && $game->playing){
        $game->join_player('timbus') if $cmd eq 'join';
        $game->ready()               if $cmd eq 'ready';
        $game->show_hand('timbus')   if $cmd eq 'hand';
        $game->show_scores('timbus') if $cmd eq 'scores';

        if ($cmd eq 'play' && !grep { /\D/ } @params){
            $game->submit_cards('timbus', @params);
        }

        if ($cmd eq 'choose' && @params > 0){
            $game->choose_winner('timbus', $params[0]);
        }
    }
});


AE::cv->recv;
