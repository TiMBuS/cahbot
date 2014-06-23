use v6;

class Card {
	has $.text;
	has $.blanks = $!text.comb(/ __+ /).elems || 1;
	
	method fill-blanks(*@cards) {
		my @filler = @cards.map("\x[1f]" ~ *.text.subst(/ '.' $/, '') ~ "\x[1f]");
		$.text.subst(/ __+ /, {shift @filler // ''}, :g) ~ @filler;
	};
}

class Deck {
	has $.cardfile = !!! 'Need to pass a card file to a deck'; 
	has @deck = $!cardfile.IO.lines.map({ Card.new(text => $^l) }).pick(*);
	has @graveyard = ();

	method deal($num = 1) {
		self!exhume if @deck < $num;
		if $num == 1 {
			@deck.shift;
		}
		else {
			@deck.splice(0, $num);
		}
	}

	method bury(*@cards) {
		@graveyard.push: @cards;
	}

	method put-back(*@cards) {
		@deck = (@deck, @cards).pick(*);
	}

	method !exhume() {
		@deck ~= @graveyard.pick(*);
		@graveyard = ();
	}
}

class Player {
	has $.name   is rw = !!! "Player needs a name";
	has $.score  is rw = 0;
	has $.active is rw = False;
	has $.vote   is rw;
	has @.hand;
	has @.submission;

	method fill-hand($deck, $cap = 10) {
		my $hand-size = @.hand.elems;
		@.hand.push: $deck.deal( $cap - $hand-size ) 
			if $hand-size < $cap;
	}

	method submit-cards(*@cards) {
		@.submission = @.hand[@cards>>.pred];
	}

	method clear-submission() {
		@.hand .= grep(none @.submission);
		@.submission = Nil;
	}
}

class PlayerStore is Array does Associative {
	has $czar-idx = 0;

	method czar {
		self[$czar-idx];
	}

	method rotate-czar() {
		return unless self > 1;
		return unless $.grep(*.active);

		repeat until self[$czar-idx].active {
			$czar-idx = ($czar-idx + 1) % self;
		}
		self[$czar-idx];
	}
	
	method at_key (Str:D $key) {
		self.first: *.name eq $key;
	}

	multi method delete_key (Cool:D $key) {
		if self.first-index(*.name eq $key) -> $i {
			self.splice($i, 1);
			$.rotate-czar if $czar-idx == $i;
		}
	}

	multi method delete_key (Player:D $key) {
		if self.first-index($key) -> $i {
			self.splice($i, 1);
			$.rotate-czar if $czar-idx == $i;
		}
	}
}

our enum Steps <Deal Submit Reveal Choose EndTurn>;
our enum Control <Pause Continue>;
our %stepnames = Steps.enums.invert;

class IRC::CAHGame {
	has $.conn    = !!!;
	has $.channel = !!!;

	method say($text) {
		$.conn.sendln("PRIVMSG $.channel :$text");
	}

	method act($text) {
		$.say("\x[01]ACTION $text\x[01]");
	}

	multi method whisper-to(Player $who, $text) {
		$.whisper-to($who.name, $text);
	}

	multi method whisper-to(Str $who, $text) {
		$.conn.sendln("NOTICE $who :$text");
	}


	has $.white-deck = Deck.new(cardfile => 'wcards.txt');
	has $.black-deck = Deck.new(cardfile => 'bcards.txt');
	has $.players = PlayerStore.new;

	has $.current-step;
	has $.black-card;
	has $.round = 1;

	has &.cleanup = ->{};

	sub increment-step($step) {
		Steps::{%stepnames{ ($step + 1) % %stepnames }};
	}

	method next-step($step?) {
		$!current-step = 
			$step // $!current-step && increment-step($!current-step) // Deal;

		while $.step($!current-step) == Continue {
			$!current-step = increment-step($!current-step);
		}
	}

	method run() {
		$.say('A game has begun! We need at least 4 people.');
		$.say('Type !join to get in on the hot, sweaty action');
	}

	method start() {
		if !defined $.current-step && $.players >= 4 {
			$.next-step;
		}
	}

	method add-player(Str $name) {
		if $.players{$name} {
			$.whisper-to($name, "You're already in, dumbass.");
			return;
		}
		$.players.push( Player.new(name => $name) );
		
		if !defined $.current-step {
			$.say("$name is in!");
			
			if $.players == 4 {
				$.say(
					'We have 4 players now. ' ~
					'You can wait for more or type !ready to start any time.'
				);
			}
		}
		else {
			$.say("$name will be joining in next turn.");
		}
	}

	method rename-player(Str $old, Str $new) {
		if $.players{$old} -> $player {
			$player.name = $new;
		}
	}

	method retire-player(Str $name) {
		if $.players{$name} -> $player {
			$.players{$player}:delete;
			return unless $player.active;

			$.say("$name is out! His final score was: \x[02]$player.score()");
			my $king-is-dead = $player === $.players.czar;
			$.white-deck.put-back($player.hand);
			
			if $.players < 4 {
				$.say("Not enough players to keep this game alive. Bye.");
				return &.cleanup();
			}
			if $king-is-dead {
				$.say("Oh no, the czar left. Let's start over..");
				for $.players.list { .submission = Nil };
				$.next-step(EndTurn);
			}
		}
	}

	method kick-player($name, $victim-name) {
		my ($player, $victim) = $.players{$name}, $.players{$victim-name};
		return unless $player && $victim; 
		return if $player.vote === $victim;
		$player.vote = $victim;

		my $count = +$.players.grep(*.vote === $victim);
		if $count < 3 {
			$.say("{$count - 3} more votes needed to kick $victim-name");
		}
		else {
			$.retire-player($victim-name);
		}
	}

	method choose-winner(Str $who, Int $choice) {
		return unless $.current-step == Choose;

		if $.players{$who} !=== $.players.czar {
			$.whisper-to($who, "Um.. You aren't the czar..");
			return;
		}
		
		my $winner = @.submitters[$choice-1];
		if !$winner {
			$.say("What? You can't pick that.");
			return;
		}
		
		$winner.score += 1;

		$.say(
			"Looks like \x[02]$winner.name()\x[02] wins this round! " ~
			"That brings him up to $winner.score() point{'s' if $winner.score != 1}! yay :>"
		);

		$.next-step();
	}

	multi method show-hand(Str $who) {
		if $.players{$who} -> $player {
			$.show-hand($player);
		}
	}

	multi method show-hand(Player $player) {
		my @prettycards = $player.hand.kv.map(-> $k, $v {
			"{$k+1}: [ $v.text() ]"
		});

		$.whisper-to($player, "Your Cards:");
		$.whisper-to($player, @prettycards[0..*/2-1].join(', '));
		$.whisper-to($player, @prettycards[*/2..*].join(', '));
	}

	method submit-cards(Str $who, *@cards) {
		return unless $.current-step == Submit;

		if $.players{$who} -> $player {
			if $player === $.players.czar {
				$.whisper-to($player, "You're the czar you idiot.");
				return;
			}
			if @cards != $.black-card.blanks {
				$.whisper-to($player, "That's not the right number of cards.");
				return;
			}
			if any(@cards) > $player.hand {
				$.whisper-to($player, "You can't play a card you don't have.");
				return;
			}
			
			$player.submit-cards(@cards);
			$.whisper-to($player, "Card(s) submitted! Thank you citizen.");

			if $.players.grep(*.submission == 0) == 1 {
				$.next-step;
			}
		}
	}

	method !build-scores($player?) {
		my $fmt = do if $player {{ 
			my $u = $player === * ?? "\x1f" !! ""; 
			"$u{.name} => {.score}$u"; 
		}}
		else {{ 
			"{.name} => {.score}" 
		}}

		"Current scores: " ~ $.players.sort(-*.score).map($fmt).join(', ');
	}

	multi method show-score(Str $who){
		if $.players{$who} -> $player {
			$.whisper-to($who, self!build-scores($player));
		}
	}
	multi method show-score() {
		$.say(self!build-scores());
	}

	multi method step(Deal) {
		for $.players.list -> $player {
			$player.active ||= True;
			$player.fill-hand($.white-deck);
		}
		$.players.rotate-czar();
		$!black-card = $.black-deck.deal[0];
		
		$.show-score() if $.round %% 5;
		
		$.say(
			"\x[02]Round $.round()\x[02]. " ~ 
			"And our card czar for this turn is.. &bullshitify-name($.players.czar.name)"
		);
		$.act(
			"reveals the next black card.."
		);
		$.say(
			"\x[02]$.black-card.text()\x[02]"
		);

		$.show-hand($_) for $.players.grep(* !=== $.players.czar);

		Continue;
	}

	multi method step(Submit) {
		$.say(
			"Time to pick your best {
				$.black-card.blanks() > 1 ?? 
					"$.black-card.blanks cards!" !! 
					"response!"
			}"
		);

		Pause;
	}
	
	has @.submitters;
	multi method step(Reveal) {
		my $czar = $.players.czar;
		@.submitters = $.players.list.grep( * !=== $czar ).pick(*);
	
		$.say("The round is over!");
		$.say("Let's all gather around and harshly judge each other's submissions now:");
		for @.submitters.kv -> $num, $player {
			$.say("\x[02]{$num+1}\x[02]: $.black-card.fill-blanks($player.submission())");
		}

		Continue;
	}

	multi method step(Choose) {
		$.say("Alright $.players.czar.name(), time to choose which one of these was the funniest.");
		Pause;
	}

	multi method step(EndTurn) {
		@.submitters = Nil;
		for $.players.list -> $player {
			$.white-deck.bury($player.submission);
			$player.clear-submission();
			$player.vote = Nil;
		}
		Continue;
	}

}

my $prefixes = <
	Mr Ms Mrs Miss 
	Master Mistress
	Monsignor
	Doctor
	Nurse
	Professor
	Honorable
	Coach
	Reverand 
	Father
	Brother
	Sister
	Superintendent
	Supernintendo
	President
	Ambassador
	Secretary
	Treasurer
	Officer
	Sargent
	Colonel
	General
>;

my $suffixes = lines q:to"END";
	a 6 out of 10 at best
	the worlds best hugger
	owner of the softest buttocks
	who was recently found not guilty
	destroyer of buffets
	#1 belieber
	who can fit like 4 cheeseburgers in his mouth at once
	the guy with the best smile
	who is probably afk
	the kawaii moe-tan who saved christmas
	the man made entirely of rice pudding
	a fan of dubs, not subs. wtf?
	a fan of subs, not dubs. wtf?
	mai kawaii waifu ^_^ 
	.. no that's really his name hahaa I know right?
	with a powerful two-hander
	who is currently sporting a raging semi
	the worst backstroke swimmer I have ever seen
	a cancer survivor
	previously deceased
	least likely to win
	the girl with rock hard titties
	but nobody cares
	a dwarf irl
	a professional youtube commenter
	with the power to morph into any invertebrate
	who will never be noticed by senpai T_T
	the girl with a huge mons pubis
	who has the swampiest pits right now
	who still owes me like 5 dollars
	who successfully cloned and ate himself
	a small child with big dreams
	who is literally the worst interior decorator
	who is not gay, but will try anything at least once (usually more)
	the cold ass nigga
	who is quite fond of bees
	who once wrote "ur gay" on his penis and made a friend look at it
	who is actually pretty mad right now
	who always slaps your back when you're coughing, which never fucking helps
	a man who helps blind people paint braille graffiti
	a wizard proficient in dentistry based magics
	the destroyer of my feelings
	the living ball of earwax
	who only recently learned how to read
	the giant, omniscient spider
	meowth, thats right
	who once touched a real girl :o 
	who wasnt invited to play, but that didnt stop him >:[ 
	survivor of 4 suicide attempts so far
	the magical fagromancer
	who was supposed to be at the yaoi anime convention like an hour ago
	a regular guy with no special traits at all
	the biggest skrillex fan
	who is so cool he sometimes wasn't picked last in gym class
	END

sub bullshitify-name (Str $name) {
	"$prefixes.roll() $name, $suffixes.roll()!";
}