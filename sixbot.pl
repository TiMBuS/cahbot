#!/usr/bin/env perl6

use v6;
use lib '.';

use Net::IRC::Bot;
use Net::IRC::Modules::Autoident;
use Net::IRC::CommandHandler;

use SixGame;

class CAHBot does Net::IRC::CommandHandler {
	has IRC::CAHGame $game;
	
	method game($ev, $match) is cmd(Long) {
		return if defined $game;
		$game .= new(
			channel => ~$ev.where, 
			conn => $ev.conn,
			cleanup => sub { $game = Nil }
		);

		#This is because I cant make a BUILD without breaking autoinit. Cool.
		$game.run;
	}

	method join($ev, $match) is cmd {
		return unless defined $game;
		$game.add-player(~$ev.who);
	}

	method start($ev, $match) is cmd(Long) {
		return unless defined $game;
		$game.start;
	};

	method score($ev, $match) is cmd {
		return unless defined $game;
		$game.show-score(~$ev.who);
	};

	method play($ev, $match) is cmd {
		return unless defined $game;

		my @cards = $match.comb(/ \d+ /).uniq;
		return unless @cards;

		$game.submit-cards(~$ev.who, @cards);
	}

	method choose($ev, $match) is cmd {
		return unless defined $game;
		if $match.match(/ \d\d? /) -> $choice {
			$game.choose-winner(~$ev.who, +$choice);
		}
	}

	method hand($ev, $match) is cmd {
		return unless defined $game;
		$game.show-hand(~$ev.who);
	}

	method quit($ev, $match) is cmd {
		return unless defined $game;
		$game.retire-player(~$ev.who);
	}

	method kick($ev, $match) is cmd(Long) {
		return unless defined $game;
		$game.kick-player(~$ev.who, ~$match);
	}

	method help($ev, $match) is cmd(Long) {

	}

	method forcedeal($ev, $match) is cmd(Long) {
		$game.next-step;
	}

	multi method nickchange($ev) {
		return unless defined $game;
		$game.rename-player(~$ev.who, $ev.what)
	}

	multi method kicked($ev) {
		return unless defined $game;
		$game.retire-player(~$ev.who);
	}

	multi method parted($ev) {
		return unless defined $game;
		$game.retire-player(~$ev.who);
	}

	multi method on-quit($ev) {
		return unless defined $game;
		$game.retire-player(~$ev.who);
	}
}


Net::IRC::Bot.new(
	nick     => 'Cahbot',
	server   => 'irc.7chan.org',
	channels => <#linux>,
	debug    => 1,

	modules  => (
		Net::IRC::Modules::Autoident.new(password => 'nspass'.IO.slurp),
		CAHBot.new(),
	),
).run;

# vim: sw=4 ft=4 noet ft=perl6
