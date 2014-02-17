use 5.016;
use Moops;

#TODO: Handle cards -way- better.
#Have a put_back and put_graveyard method. So no dupes.
class Deck {
    use Tie::File;
    use List::Util qw(shuffle);

    has cardfile => (is => 'ro',  isa => Str);
    has cards    => (is => 'ro',  isa => ArrayRef, builder => 1, lazy => 1);
    
    has order    => (is => 'rwp', isa => ArrayRef, default => sub {[]} );

    method _build_cards() {
        tie my @array, 'Tie::File', $self->cardfile or die "Uh oh: $!";
        \@array;
    }

    method deal(Int $num = 1) {
        if (@{$self->order} < $num) {
            push $self->order, shuffle(0 .. @{$self->cards}-1);
        }
        return [ @{$self->cards}[ splice $self->order, 0, $num ] ];
    }
}

class Player {
    has 'name'   => (is => 'rw');
    has 'score'  => (is => 'rwp', isa => Int, default => 0);
    has 'hand'   => (is => 'ro', isa => ArrayRef, default => sub {[]});

    method swap_card(Str $newcard, Int $index) {
        $self->hand->[$index-1] = $newcard;
    }

    method give_cards(ArrayRef $cards) {
        push $self->hand, @$cards;
    }

    method add_score(Int $score) {
        $self->_set_score($self->score + $score);
    }
}

class Game {
    use Coro;
    use Coro::AnyEvent;

    has irc         => (is => 'ro');
    has playing     => (is => 'rwp', default => 1);
    has channel     => (is => 'rwp');
    has min_players => (is => 'ro', default => 4);
 
    has black_deck  => (is => 'ro',  isa => 'Deck', builder => 1);
    has white_deck  => (is => 'ro',  isa => 'Deck', builder => 1);

    has step        => (is => 'rwp');
    has step_rouse  => (is => 'rwp');

    has submissions => (is => 'rwp');
    has blank_count => (is => 'rwp');

    method _build_black_deck {
        Deck->new(cardfile => 'bcards.txt');
    }

    method _build_white_deck {
        Deck->new(cardfile => 'wcards.txt');
    }

    method BUILD {
        $self->init();
    }

    method init() { async {
        #Lobby up.
        $self->_set_step('lobby');
        $self->_set_step_rouse(Coro::rouse_cb);

        $self->say("A game has begun!! We need at least ${\$self->min_players} people.");
        $self->say('Type !join to get in on the hot, sweaty action (no fat chicks).');
        
        Coro::rouse_wait();
        
        #It's game time.
        my $first_turn = 1;
        my $round_count = 0;
        while ($self->playing) {

            $self->_set_step('reveal');

            my $turn = $first_turn ? 'First turn!' : 'Next turn!';
            $first_turn = 0;

            $round_count = ($round_count+1) % 5;
            $self->show_scores if $round_count == 0;

            my $czar = $self->next_czar;
            $self->say(
                "$turn And our card czar for this turn is.. " . 
                bullshitify_name($czar->name)
            );
            Coro::AnyEvent::sleep(2);
            $self->act('reveals the next black card..');

            my $black_card = $self->black_deck->deal()->[0];
            my $num_answers = count_blanks($black_card);

            $self->say("$black_card");

            $self->notice_player_cards($_) for grep {$_ != $self->czar} @{$self->player_array};

            my $rouser = Coro::rouse_cb;
            $self->_set_blank_count($num_answers);
            $self->_set_step_rouse($rouser);
            $self->_set_submissions(my $submissions = {});
            $self->_set_step('submit');

            Coro::AnyEvent::sleep(4);

            if ($num_answers > 1){
                $self->say("Time to pick your best $num_answers cards!");
            }
            else {
                $self->say('Time to pick your best response!');
            }

            my $reminder = AE::timer 90, 40, sub { 
                my %slowasses;
                @slowasses{(keys $self->player_hash)} = ();
                delete @slowasses{(keys $submissions), lc $self->czar->name};

                $self->say( 
                    "Still waiting on answers from ". 
                    join ', ', 
                    map {$self->player_hash->{$_}->name} 
                    keys %slowasses 
                ); 
            };
            Coro::rouse_wait($rouser);
            undef $reminder;

            $self->_set_step('show_answers');

            $self->say("The round is over!");

            $self->say("Let's all gather around and harshly judge each other's submissions now:");
            my $submap = {};
            my $num = 0;
            while (my ($player_name, $cards) = each $submissions) {
                my $player = $self->player_hash->{$player_name};
                next unless defined $player;
                Coro::AnyEvent::sleep(1);

                $submap->{++$num} = $player;
                my $joke = fill_blanks($black_card, @{$player->hand}[@$cards]);
                $self->say("$num: $joke");
            }
            if (defined $self->czar && defined $self->player_hash->{lc $self->czar->name}) {
                Coro::AnyEvent::sleep(1);
                $self->say("Alright ${\$czar->name}, time to choose which one of these was the funniest.");
                
                $self->_set_step('choose');
                $self->_set_step_rouse(Coro::rouse_cb);

                my $chosen = Coro::rouse_wait;
                if (defined $chosen){
                    my $winner = $submap->{$chosen};
                    my $points = $winner->add_score(1);
                    $self->say("Looks like ${\$winner->name} wins this round! That brings him up to $points point" . (($points != 1) ? "s!" : "! yay :>"));
                }
                else {
                    $self->say('Oh, no czar? Well fuck that, let\'s move on.');
                }
            }
            else {
                $self->say('Oh, no czar? Well fuck that, let\'s move on.');
            }
            $self->_set_step('postamble');
            #Card fiddle..
            while (my ($player_name, $idx) = each $submissions) {
                my $player = $self->player_hash->{$player_name};
                next unless defined $player;
                my $new_cards = $self->white_deck->deal(scalar @$idx);
                @{$player->hand}[@$idx] = @$new_cards;

                my $i = 0;
                my $pretty_cards = 
                    join ', ', 
                    map {$idx->[$i++] + 1 . ": [ $_ ]"} 
                    @$new_cards;
            }

            if ($self->player_count < $self->min_players) {
                $self->_set_playing(0);
                $self->say('Not enough people to keep the game alive. GG.');
            }

            Coro::AnyEvent::sleep(3);
        }
    }}

    has join_queue => (is => 'rwp', default => sub {{}});
    method join_player($name) {
        return unless $self->playing;
        return if defined $self->player_hash->{lc $name} || defined $self->join_queue->{lc $name};

        if ($self->step eq 'lobby') {
            my $player = Player->new(name => $name);
            $self->add_player($player);

            $self->say("$name is in!");

            if ($self->player_count == $self->min_players) {
                $self->say(
                    "We have ${\$self->min_players} players now. ".
                    'You can wait for more or type !ready to start any time.'
                );
            }

            my $hand = $self->white_deck->deal(10);
            $player->give_cards($hand);
        }
        else {
            $self->say("$name will be joining in next turn.");
            $self->join_queue->{lc $name} = Player->new(name => $name);
        }
    }

    after _set_step {
        return unless $self->step eq 'reveal';

        for my $player (values $self->join_queue){
            $self->add_player($player);
            my $hand = $self->white_deck->deal(10);
            $player->give_cards($hand);
        }

        $self->_set_join_queue({});
    };

    method ready(Str $who) {
        return unless $self->step eq 'lobby' && $self->player_count >= $self->min_players;
        return unless defined $self->player_hash->{lc $who};
        $self->step_rouse->();
    }

    method submit_cards($name, @cards) {
        return unless $self->step eq 'submit';
        if (@cards < $self->blank_count) {
            $self->say_to($name, 'Too few cards! You need to submit '.$self->blank_count);
            return;
        }
        if (@cards > $self->blank_count) {
            $self->say_to($name, 'Too many cards! You need to submit '.$self->blank_count);
            return;
        }
        
        my $player = $self->player_hash->{lc $name} //
            return $self->say_to($name, 'You aren\'t even playing! Wtf.');

        if ($player == $self->czar) {
            return $self->say('The czar can\'t play a card =/');
        }

        if (grep {$_ < 1 || $_ > @{$player->hand}} @cards) {
            return $self->say_to($name, 'Trying to play a card you don\'t have? How crafty..');
        }


        $self->submissions->{lc $player->name} = [map {$_-1} @cards];
        $self->say_to($name, 'Card(s) submitted!');

        $self->step_rouse->() if keys $self->submissions >= $self->player_count-1;
    }

    method choose_winner (Str $czar_name, Int $chosen) {
        return unless $self->step eq 'choose';
        if (lc $czar_name ne lc $self->czar->name) {
            $self->say_to($czar_name, 'Wtf you arent the czar.');
            return;
        }
        if ($chosen <= 0 || $chosen > $self->player_count-1) {
            $self->say("Uhh.. Pick one that exists plz");
            return;
        }

        $self->step_rouse->($chosen);
    }

    method show_hand(Str $who) {
        my $player = $self->player_hash->{lc $who};
        if (defined $player){
            $self->notice_player_cards($player);
        }
    }

    multi method show_scores(Str $who) {
        my $player = $self->player_hash->{lc $who};
        if (defined $player){
            $self->say_to($who, "Current scores: " . 
                join ', ',
                map {($player == $_ ? ''.$_->name.'' : $_->name) .' -> '. $_->score}
                sort {$b->score <=> $a->score} 
                @{$self->player_array}
            );
        }
    }
    multi method show_scores() {
        $self->say("Current scores: " . 
            join ', ',
            map { $_->name .' -> '. $_->score }
            sort {$b->score <=> $a->score} 
            @{$self->player_array}
        );
    }

    method unjoin(Str $who) {
        if (my $dead = $self->remove_player($who)) {
            $self->say(
                "$who is out." . 
                (($self->step ne 'lobby') ? " His final score was: ${\$dead->score}" : "")
            );
            
            $self->step_rouse->() 
                if $self->step eq 'submit' && keys $self->submissions >= $self->player_count-1;

            $self->step_rouse->() 
                if $self->step eq 'choose' && $dead == $self->czar;
        }

    }

    has kicktally => (is => 'rw', default => sub{{}});
    after _set_step { $self->kicktally({}) };

    method kick(Str $voter_name, Str $target_name) {
        my $bully  = $self->player_hash->{lc $voter_name};
        my $victim = $self->player_hash->{lc $target_name};
        return unless defined $bully && defined $victim;

        if ($self->step eq 'submit' || $self->step eq 'choose' ) {
            $self->kicktally->{$victim}{$bully} = 1;

            my $tally = keys $self->kicktally->{$victim};
            my $needed = int ( $self->player_count / 2 );
            
            if ($tally >= $needed) {
                $self->unjoin($target_name);
            }
            else {
                $self->say("$tally out of a needed $needed votes to kick ${\$victim->name}");
            }
        }
    }

    method say($msg) {
        $self->irc->send_msg(PRIVMSG => $self->channel, $msg);
    }

    method say_to($who, $msg) {
        $self->irc->send_msg(NOTICE => $who, $msg);
    }

    method act($msg) {
        $self->irc->send_msg(PRIVMSG => $self->channel, "\x{01}ACTION $msg\x{01}");
    }


    has player_hash  => (is => 'ro',  default => sub {{}});
    has player_array => (is => 'ro',  default => sub {[]});
    has czar_idx     => (is => 'rwp', default => 0);
    has czar         => (is => 'rwp', default => 0);

    method player_count {
        @{$self->player_array}
    }

    method add_player(Player $player) {
        $self->player_hash->{lc $player->name} = $player;
        push $self->player_array, $player;
    }

    method rename_player(Str $old_name, Str $new_name){
        for my $store ($self->player_hash, $self->join_queue) {
            my $player = delete $store->{lc $old_name} // next;
            $player->name($new_name);
            $store->{lc $new_name} = $player;
        }
    }

    method remove_player(Str $name){
        my $player;
        for my $store ($self->player_hash, $self->join_queue) {
            $player = delete $store->{lc $name} // next;
        }
        return unless $player;

        if ($self->step eq 'submit') {
            delete $self->submissions->{lc $name};
        }

        my $index = 0; my $players = $self->player_array;
        $index++ until $index >= @$players || $players->[$index] == $player;
        splice $players, $index, 1;

    }

    method next_czar {
        my $newidx = $self->_set_czar_idx(
            ($self->czar_idx+1) % $self->player_count
        );
        $self->_set_czar($self->player_array->[$newidx]);
    }


    method notice_player_cards(Player $player) {
        my $cardnum = 0;
        $self->say_to($player->name, 'These are your cards:');
        my @prettycards = map { ++$cardnum . ": [ $_ ]" } @{$player->hand};

        my $hand_idx = @prettycards-1;
        my $half_hand_idx = int $hand_idx/2;
        $self->say_to($player->name, join ', ', @prettycards[0..$half_hand_idx]);
        $self->say_to($player->name, join ', ', @prettycards[$half_hand_idx+1..$hand_idx]);
    }



    fun count_blanks (Str $card) {
        my $ret =()= $card =~ /__+/g;
        $ret = 1 if $ret == 0;
        $ret;
    }

    fun fill_blanks (Str $card, @fillings) {
        #Bit of pre-treatment on the text
        #TODO this is broke for punctuation.
        @fillings = map {s/\.$//; "\x{1f}$_\x{1f}"} @fillings;

        $card =~ s|__+|{shift @fillings // ''}|eg;
        $card .= ' ' . join ' ', @fillings if (@fillings != 0);
        return $card;
    }

    fun bullshitify_name (Str $name) {
        state $prefixes = [qw{
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
        }];

        state $suffixes = [
            'a 6 out of 10 at best',
            'the worlds best hugger',
            'owner of the softest buttocks',
            'who was recently found not guilty',
            'destroyer of buffets',
            '#1 belieber',
            'who can fit like 4 cheeseburgers in his mouth at once',
            'the guy with the best smile',
            'who is probably afk',
            'the kawaii moe-tan who saved christmas',
            'the man made entirely of rice pudding',
            'a fan of dubs, not subs. wtf?',
            'a fan of subs, not dubs. wtf?',
            'mai kawaii waifu ^_^ ',
            '.. no that\'s really his name hahaa I know right?',
            'with a powerful two-hander',
            'who is currently sporting a raging semi',
            'the worst backstroke swimmer I have ever seen',
            'a cancer survivor',
            'previously deceased',
            'least likely to win',
            'the girl with rock hard titties',
            'but nobody cares',
            'a dwarf irl',
            'a professional youtube commenter',
            'with the power to morph into any invertebrate',
            'who will never be noticed by senpai T_T',
            'the girl with a huge mons pubis',
            'who has the swampiest pits right now',
            'who still owes me like 5 dollars',
            'who successfully cloned and ate himself',
            'a small child with big dreams',
            'who is literally the worst interior decorator',
            'who is not gay, but will try anything at least once (usually more)',
            'the cold ass nigga',
            'who is quite fond of bees',
            'who once wrote "ur gay" on his penis and made a friend look at it',
            'who is actually pretty mad right now',
            'who always slaps your back when you\'re coughing, which never fucking helps',
            'a man who helps blind people paint braille graffiti',
            'a wizard proficient in dentistry based magics',
            'the destroyer of my feelings',
            'the living ball of earwax',
            'who only recently learned how to read',
            'the giant, omniscient spider',
            'meowth, thats right',
            'who once touched a real girl :o ',
            'who wasnt invited to play, but that didnt stop him >:[ ',
            'survivor of 4 suicide attempts so far',
            'the magical fagromancer',
            'who was supposed to be at the yaoi anime convention like an hour ago',
            'a regular guy with no special traits at all',
            'the biggest skrillex fan',
            'who is so cool he sometimes wasn\'t picked last in gym class',
        ];

        return sprintf '%s %s, %s!', $prefixes->[int rand @$prefixes], $name , $suffixes->[int rand @$suffixes];
    }
}
