#!/usr/bin/env perl6

use v6;
use lib '.';

use Net::IRC::Bot;
use Net::IRC::Modules::Autoident;
use Net::IRC::CommandHandler;

use SixGame;

class CAHBot does Net::IRC::CommandHandler {
	has IRC::CAHGame $game;

	method game($ev, $match) is cmd(:abbreviate(False)) {
		return if defined $game;
		$game .= new(
			channel => lc(~$ev.where),
			conn    => $ev.conn,
			cleanup => sub { $game = Nil }
		);

		#This is because I cant make a BUILD without breaking autoinit. Cool.
		$game.run;
	}

	method join($ev, $match) is cmd {
		return unless defined $game;
		$game.add-player(lc(~$ev.who));
	}

	method start($ev, $match) is cmd(:abbreviate(False)) {
		return unless defined $game;
		$game.start;
	};

	method score($ev, $match) is cmd {
		return unless defined $game;
		$game.show-score(lc(~$ev.who));
	};

	method play($ev, $match) is cmd {
		return unless defined $game;

		my @cards = $match.comb(/ \d+ /).unique;
		return unless @cards;

		$game.submit-cards(lc(~$ev.who), @cards);
	}

	method choose($ev, $match) is cmd {
		return unless defined $game;
		if $match.match(/ \d\d? /) -> $choice {
			$game.choose-winner(lc(~$ev.who), +$choice);
		}
	}

	method hand($ev, $match) is cmd {
		return unless defined $game.?current-step;
		$game.show-hand(lc(~$ev.who));
	}

	method quit($ev, $match) is cmd {
		return unless defined $game;
		$game.retire-player(lc(~$ev.who));
	}

	method kick($ev, $match) is cmd(:abbreviate(False)) {
		return unless defined $game;
		$game.kick-player(lc(~$ev.who), lc(~$match));
	}

	method help($ev, $match) is cmd(:abbreviate(False)) {
		$ev.msg(
			'Commands: !game to start a game, !join to get in, '~
			'!hand to see your hand, !play <num> to play a card, '~
			'!choose <num> to pick a winner (as czar), '~
			'!score to see your score, !kick to kick a player, '~
			'!quit to leave',
			$ev.who
		);
	}

	method forcenext($ev, $match) is cmd(:abbreviate(False)) {
		$game.next-step;
	}

	multi method nickchange($ev) {
		return unless defined $game;
		$game.rename-player(lc(~$ev.who), lc(~$ev.what));
	}

	multi method kicked($ev) {
		return unless defined $game;
		$game.retire-player(lc(~$ev.what));
	}

	multi method parted($ev) {
		return unless defined $game;
		$game.retire-player(lc(~$ev.who));
	}

	multi method on-quit($ev) {
		return unless defined $game;
		$game.retire-player(lc(~$ev.who));
	}

	method spamshit($ev, $match) is cmd(:abbreviate(False)) {
		return unless defined $game;

		with $game.players.grep(*.active) -> @active-players {
			$ev.msg: "The current players are: " ~ @active-players>>.name.join(', ');
		}
		with $game.players.grep(! *.active) -> @inactive-players {
			$ev.msg: "The queued players are: " ~ @inactive-players>>.name.join(', ');
		}

		if $game.current-step -> $step {
			$ev.msg: "The current step is: " ~ $step;
		}
	}
}

sub MAIN ($channel = '#linux') {
	Net::IRC::Bot.new(
		nick     => 'Cahbot',
		server   => 'irc.7chan.org',
		channels => [$channel],
		debug    => 1,

		modules  => (
			Net::IRC::Modules::Autoident.new(password => 'nspass'.IO.slurp),
			CAHBot.new(),
		),
	).run;
}

# vim: sw=4 ft=4 noet ft=perl6
