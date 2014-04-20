##
# casino blackjack simulator
#
# auth: tommy balboa (tbalboa)
#       will storey (horgh)
# date: 2010-05-24
#

namespace eval ::blackjack {
	variable version 1.0

	variable chans ""
	variable delay 10
	variable insurance_time 10
	variable turn_expire 60
	variable debug 0
	variable file "balances.db"
	variable compressed 1

	variable output_cmd ::blackjack::putnow

	# rules
	variable decks 4
	variable min 25
	variable max 500
	variable stay 17

	# game	
	variable deck [list]
	variable deck_retired [list]
	variable players_waiting [list]
	variable players_table [list]

	variable active_player -1
	variable is_game_active 0
	variable is_hand_active 0
	variable can_insure 0

	variable players [dict create]
	variable house [dict create]

	variable expire_id {}
	variable insurance_id {}

	bind pub -|- ".start" ::blackjack::start
	bind pub -|- ".stop" ::blackjack::stop

	bind pub -|- ".sit" ::blackjack::sit
	bind pub -|- ".stand" ::blackjack::stand
	bind pub -|- ".bet" ::blackjack::bet

	bind pub -|- ".balance" ::blackjack::say_balance
	bind pub -|- ".buy" ::blackjack::buy
	bind pub -|- ".reset" ::blackjack::reset
	bind pub -|- ".top10" ::blackjack::top10

	bind pub -|- "h" ::blackjack::hit
	bind pub -|- "s" ::blackjack::stay
	bind pub -|- "i" ::blackjack::insurance
	bind pub -|- "d" ::blackjack::double
	bind pub -|- "sr" ::blackjack::surrender
	bind pub -|- "sp" ::blackjack::split_hand

	bind evnt -|- "save" ::blackjack::save_players
}

proc ::blackjack::main {} {
	if {![::blackjack::is_game_active]} {
		return
	}

	dict unset ::blackjack::house cards
	set ::blackjack::active_player -1

	::blackjack::cleanup_players
	::blackjack::include_waiting_players
	::blackjack::reset_players
	::blackjack::set_hand_active 1

	::blackjack::deal
}

proc ::blackjack::start {nick host hand chan argv} {
	if {[::blackjack::is_game_active]} {
		::blackjack::msg "The game is already running."
		return
	}

	::blackjack::msg "Starting game in $::blackjack::delay seconds..."
	::blackjack::set_game_active 1

	# start with new deck/retired deck
	set ::blackjack::deck_retired []
	::blackjack::set_deck
	utimer $::blackjack::delay ::blackjack::main
	# sit the player who .start'd automatically
	::blackjack::sit $nick $host $hand $chan $argv
}

proc ::blackjack::stop {nick host hand chan argv} {
	if {![isop $nick $chan]} { return }

	# make sure insurance is turned off
	::blackjack::set_insurable 0
	::blackjack::stop_game
	::blackjack::msg "Stopping game."
}


proc ::blackjack::buy {nick host hand chan argv} {
	if {![::blackjack::is_valid_bet $argv]} {
		::blackjack::msg "Can only buy \$$::blackjack::min to \$$::blackjack::max at a time."
		return
	}

	set data [::blackjack::buy_chips $nick $argv]
	::blackjack::msg "$nick bought [::blackjack::dollars $argv] chips, ([::blackjack::dollars [lindex $data 0]]:[::blackjack::dollars [lindex $data 1]])"
}

proc ::blackjack::buy_chips {player amount} {
	set balance [expr {[::blackjack::get_balance $player] + $amount}]
	set bought [expr {[::blackjack::get_bought $player] + $amount}]
	::blackjack::set_balance $player $balance
	dict set ::blackjack::players $player bought $bought

	return [list $bought $balance]
}

proc ::blackjack::stop_game {} {
	if {![::blackjack::is_game_active]} {
		::blackjack::msg "Game isn't running."
		return
	}

	::blackjack::set_game_active 0
	::blackjack::set_hand_active 0
	::blackjack::reset_players

	dict unset ::blackjack::house cards
	set ::blackjack::active_player -1
	set ::blackjack::players_table [list]
	set ::blackjack::players_waiting [list]
	set ::blackjack::deck [list]
}

proc ::blackjack::sit {nick host hand chan argv} {
	if {![::blackjack::is_game_active]} {
		return
	}

	if {![::blackjack::is_sitting $nick]} {
		if {![::blackjack::has_profile $nick]} {
			::blackjack::buy_chips $nick 100
		}

		if {![::blackjack::has_chips $nick]} {
			::blackjack::msg "$nick: buy some chips first."
			return
		}

		dict set ::blackjack::players $nick bet $::blackjack::min
		dict set ::blackjack::players $nick active 0
		if {[::blackjack::is_hand_active]} {
			if {![::blackjack::is_waiting $nick]} {
				lappend ::blackjack::players_waiting $nick
				::blackjack::msg "$nick is waiting to sit down."
			}
		} else {
			lappend ::blackjack::players_table $nick
			::blackjack::msg "$nick sat down."
		}
	}
}

proc ::blackjack::stand {nick host hand chan argv} {
	if {![::blackjack::is_game_active]} {
		return
	}

	if {[::blackjack::is_sitting $nick] && ![::blackjack::wants_to_stand $nick]} {
		dict set ::blackjack::players $nick stand 1
		if {[::blackjack::is_hand_active]} {
			::blackjack::msg "last hand for $nick"
		} else {
			::blackjack::msg "$nick left the table"
		}
	}
}

proc ::blackjack::bet {nick host hand chan argv} {
	if {![::blackjack::is_game_active]} {
		return
	}

	if {[::blackjack::is_sitting $nick]} {
		if {[::blackjack::is_valid_bet $argv]} {
			if {[::blackjack::check_balance $nick $argv]} {
				if {[::blackjack::is_hand_active]} {
					dict set ::blackjack::players $nick next_bet $argv
					::blackjack::msg "$nick : next bet is [::blackjack::dollars $argv]"
				} else {
					dict set ::blackjack::players $nick bet $argv
					::blackjack::msg "$nick bet [::blackjack::dollars $argv]"
				}
			} else {
				::blackjack::msg "Insufficient funds. You may have a gambling problem."
			}
		} else {
			::blackjack::msg "Minimum bet: [::blackjack::dollars $::blackjack::min], maximum bet: [::blackjack::dollars $::blackjack::max]."
		}
	}
}

proc ::blackjack::split_hand {nick host hand chan argv} {
	::blackjack::msg "::split $nick"
	if {![::blackjack::is_game_active] || [::blackjack::is_insurable]} {
		return
	}

	if {[::blackjack::is_active_player $nick] && [::blackjack::can_split $nick]} {
		set cards [::blackjack::get_player_cards $nick]
		set count [llength [::blackjack::get_hands $nick]]
		dict set ::blackjack::players $nick hand 0 cards [list [lindex $cards 0]]
		dict set ::blackjack::players $nick hand $count cards [list [lindex $cards 1]]
		if {[::blackjack::card_status $nick [::blackjack::get_player_cards $nick]]} {
			::blackjack::next
		}
	}
}

proc ::blackjack::can_split {player} {
	set cards [::blackjack::get_player_cards $player]
	if {[llength $cards] != 2} {
		return 0
	}

	for {set i 1} {$i < [llength [::blackjack::get_hands $player]]} {incr i} {
		lappend cards {*}[::blackjack::get_player_cards $player $i]
	}

	foreach card $cards {
		if {[::blackjack::count [list [lindex $cards 0]]] != [::blackjack::count [list $card]]} {
			return 0
		}
	}

	return 1
}

proc ::blackjack::say_balance {nick host hand chan argv} {
	if {[string length $argv] > 0} {
		set nick [string trim $argv]
	}
	if {[::blackjack::has_profile $nick]} {
		::blackjack::msg "$nick has [::blackjack::dollars [::blackjack::get_balance $nick]] ([::blackjack::dollars [::blackjack::get_bought $nick]] bought)"
	} else {
		::blackjack::msg "$nick doesn't have a balance."
	}
}

proc ::blackjack::reset {nick host hand chan argv} {
	if {[::blackjack::has_profile $nick]} {
		if {![::blackjack::is_sitting $nick]} {
			::blackjack::set_balance $nick 0
			::blackjack::set_bought $nick 0
			::blackjack::buy_chips $nick 100
			::blackjack::msg "$nick's balance set to [::blackjack::dollars [::blackjack::get_balance $nick]]"
		}
	} else {
		::blackjack::msg "$nick doesn't have a balance."
	}
}

proc ::blackjack::top10 {nick host hand chan argv} {
	# extract balances and names for sorting
	dict for {name data} $::blackjack::players {
		dict with data {
			lappend balances [list $balance $name]
		}
	}
	# sort and truncate to 10
	set balances [lrange [lsort -index 0 -real -decreasing $balances] 0 9]

	set output []
	set num 0
	foreach balance $balances {
		set output "${output}#[incr num] \002[lindex $balance 1]\002: [::blackjack::dollars [lindex $balance 0]] "
	}
	::blackjack::msg $output
}

proc ::blackjack::hit {nick host hand chan argv} {
	if {![::blackjack::is_game_active] || [::blackjack::is_insurable]} {
		return
	}

	if {[::blackjack::is_active_player $nick]} {
		::blackjack::add_card $nick [::blackjack::card]
		if {[::blackjack::card_status $nick [::blackjack::get_player_cards $nick]]} {
			::blackjack::next
		}
	}
}

proc ::blackjack::double {nick host hand chan argv} {
	if {![::blackjack::is_game_active] || [::blackjack::is_insurable]} {
		return
	}

	if {[::blackjack::is_active_player $nick] && [::blackjack::can_double $nick]} {
		set double [expr {[::blackjack::get_bet $nick] * 2}]
		if {[::blackjack::check_balance $nick $double]} {
			::blackjack::set_doubled $nick
			::blackjack::msg "$nick : doubled bet to [::blackjack::dollars $double]"
			::blackjack::add_card $nick [::blackjack::card]
			::blackjack::card_status $nick [::blackjack::get_player_cards $nick]
			::blackjack::next
		} else {
			::blackjack::msg "$nick doesn't have enough money to double up."
		}
	}
}

proc ::blackjack::stay {nick host hand chan argv} {
	if {![::blackjack::is_game_active] || [::blackjack::is_insurable]} {
		return
	}

	if {[::blackjack::is_active_player $nick]} {
		::blackjack::next
	}
}

proc ::blackjack::insurance {nick host hand chan argv} {
	if {![::blackjack::is_game_active] || ![::blackjack::is_insurable]} {
		return
	}

	if {[::blackjack::is_sitting $nick] && ![::blackjack::is_insured $nick]} {
		if {[::blackjack::may_insure $nick]} {
			::blackjack::set_insured $nick

			if {[::blackjack::all_insured]} {
				::blackjack::close_insurance
			}
		} else {
			::blackjack::msg "$nick doesn't have enough money for insurance."
		}
	}
}

proc ::blackjack::surrender {nick host hand chan argv} {
	if {![::blackjack::is_game_active] || ![::blackjack::is_hand_active]} {
		return
	}

	if {[::blackjack::is_sitting $nick] && ![::blackjack::has_surrendered $nick]} {
		set loss [::blackjack::surrender_helper $nick]
		::blackjack::msg "$nick surrendered. [::blackjack::dollars $loss]."
		::blackjack::next
	}
}

proc ::blackjack::surrender_helper {player} {
	if {$::blackjack::debug} { putlog "::surrender_helper $player" }

	set loss [::blackjack::balance $player -0.5 -0.5]
	::blackjack::set_surrendered $player

	return $loss
}

proc ::blackjack::remove_player {player} {
	if {$::blackjack::debug} { putlog "::remove_player $player" }
	::blackjack::reset_player $player

	if {[set i [lsearch $::blackjack::players_table $player]] != -1} {
		set ::blackjack::players_table [lreplace $::blackjack::players_table $i $i]
		if {$::blackjack::active_player >= $i} {
			incr ::blackjack::active_player -1
		}
	} elseif {[set i [lsearch $::blackjack::players_waiting $player]] != -1} {
		set ::blackjack::players_waiting [lreplace $::blackjack::players_waiting $i $i]
	}
}

proc ::blackjack::reset_players {} {	
	if {$::blackjack::debug} { putlog "::reset_players" }
	foreach player [::blackjack::get_players] {
		::blackjack::reset_player $player
	}
}

proc ::blackjack::reset_player {player} {
	if {$::blackjack::debug} { putlog "::reset_player $player" }

	::blackjack::update_bets
	dict unset ::blackjack::players $player stand
	dict unset ::blackjack::players $player insured
	dict unset ::blackjack::players $player hand
	dict set ::blackjack::players $player active 0
}

proc ::blackjack::cleanup_players {} {
	if {$::blackjack::debug} { putlog "::cleanup_players" }
	set players [list]
	foreach player [::blackjack::get_players] {
		if {![::blackjack::is_missing $player] && ![::blackjack::wants_to_stand $player] && [::blackjack::has_own_bet $player]} {
			lappend players $player
		} else {
			::blackjack::reset_player $player
		}
	}

	::blackjack::set_players $players
}

proc ::blackjack::include_waiting_players {} {
	if {$::blackjack::debug} { putlog "::include_waiting_players" }
	if {![llength $::blackjack::players_waiting]} {
		return
	}

	foreach player $::blackjack::players_waiting {
		lappend ::blackjack::players_table $player
	}

	set ::blackjack::players_waiting [list]	
}

proc ::blackjack::card_status {player card_list} {
	if {$::blackjack::debug} { putlog "::card_status $player $card_list" }
	set total [::blackjack::count $card_list]
	set str "[::blackjack::print_cards $card_list] ($total)"

	switch -- [::blackjack::hand $total] {
		blackjack {
			::blackjack::msg "$player : Blackjack! $str"
			return 2
		}

		bust {	
			::blackjack::msg "$player : Bust! $str"
			return 1
		}
	}
		
	::blackjack::msg "$player : $str"
	return 0
}

proc ::blackjack::set_deck {} {
	::blackjack::msg "\001ACTION shuffles the cards\001"

	# use retired cards if game is active, otherwise make new deck
	if {[::blackjack::is_game_active] && [llength $::blackjack::deck_retired] > 0} {
		set ::blackjack::deck [::blackjack::shuffle $::blackjack::deck_retired]
		set ::blackjack::deck_retired []
	} else {
		set ::blackjack::deck [::blackjack::shuffle [::blackjack::deck $::blackjack::decks]]
	}
}

proc ::blackjack::is_missing {player} {
	if {$::blackjack::debug} { putlog "::is_missing $player" }
	foreach chan $::blackjack::chans {
		if {[onchan $player $chan]} {
			return 0
		}
	}

	return 1
}

proc ::blackjack::deal {} {
	if {$::blackjack::debug} { putlog "::deal" }
	if {![::blackjack::is_game_active]} {
		return
	}

	if {![llength [::blackjack::get_players]]} {
		::blackjack::msg "Stopping game since no one is playing."
		::blackjack::stop_game

		return
	}

	for {set i 0} {$i < 2} {incr i} {
		foreach player [::blackjack::get_players] {
			::blackjack::add_card $player [::blackjack::card]
		}
		dict lappend ::blackjack::house cards [::blackjack::card]
	}

	lappend initial_print "House : [::blackjack::pretty_card_list [list [lindex [::blackjack::get_house_cards] 0]]]"
	foreach player [::blackjack::get_players] {
		lappend initial_print "$player : [::blackjack::pretty_card_list [::blackjack::get_player_cards $player]]"
	}

	::blackjack::msg [join $initial_print {, }]
	if {![::blackjack::offer_insurance]} {
		::blackjack::next
	}
}

proc ::blackjack::pretty_card_list {card_list} {
	if {$::blackjack::debug} { putlog "::pretty_card_list $card_list" }
	set total [::blackjack::count $card_list]

	return "[::blackjack::print_cards $card_list] ($total)"
}

proc ::blackjack::add_card {player card} {
	set active [::blackjack::get_active_hand $player]
	if {[dict exists $::blackjack::players $player hand $active cards]} {
		set cards [::blackjack::get_player_cards $player]
	}

	lappend cards $card
	dict set ::blackjack::players $player hand $active cards $cards
}
proc ::blackjack::get_active_hand {player} {
	return [dict get $::blackjack::players $player active]
}

proc ::blackjack::get_hands {player} {
	return [dict keys [dict get $::blackjack::players $player hand]]
}

proc ::blackjack::msg {argv} {
	foreach chan $::blackjack::chans {
		foreach line [::blackjack::split_line 400 $argv] {
			$::blackjack::output_cmd "PRIVMSG $chan :$line"
		}
	}
}

proc ::blackjack::next {} {
	if {$::blackjack::debug} { putlog "::next" }
	set player [::blackjack::get_active_player]
	if {![string match {} $player]} {
		::blackjack::incr_hand $player
		if {[::blackjack::get_active_hand $player] >= [llength [::blackjack::get_hands $player]]} {
			incr ::blackjack::active_player
		}
	} else {
		incr ::blackjack::active_player
	}
	if {$::blackjack::active_player >= [llength [::blackjack::get_players]]} {
		::blackjack::cancel_timeout
		set ::blackjack::active_player -1
		::blackjack::house
	} else {
		set player [::blackjack::get_active_player]
		::blackjack::init_timeout
		if {[::blackjack::card_status $player [::blackjack::get_player_cards $player]]} {
			::blackjack::next
		}
	}
}

proc ::blackjack::incr_hand {player} {
	set active [::blackjack::get_active_hand $player]
	dict set ::blackjack::players $player active [incr active]
}

proc ::blackjack::expire_player {} {
	set ::blackjack::expire_id {}
	if {![::blackjack::is_game_active] || ![::blackjack::is_hand_active]} {
		return
	}

	set player [::blackjack::get_active_player]
	set loss [::blackjack::surrender_helper $player]

	::blackjack::msg "$player was removed from the table. Lost [::blackjack::dollars $loss]."
	::blackjack::remove_player $player
	::blackjack::next
}

proc ::blackjack::init_timeout {} {
	::blackjack::cancel_timeout
	set ::blackjack::expire_id [utimer $::blackjack::turn_expire ::blackjack::expire_player]
}

proc ::blackjack::cancel_timeout {} {
	if {![string match {} $::blackjack::expire_id]} {
		killutimer $::blackjack::expire_id
		set ::blackjack::expire_id {}
	}
}

proc ::blackjack::house {} {
	if {$::blackjack::debug} { putlog "::house" }

	::blackjack::card_status "House" [::blackjack::get_house_cards]
	while {[set house_total [::blackjack::count [::blackjack::get_house_cards]]] < $::blackjack::stay} {
		dict lappend ::blackjack::house cards [::blackjack::card]
		::blackjack::card_status "House" [::blackjack::get_house_cards]
	}

	set i_ratio -1
	if {$house_total == 21} {
		set i_ratio 2
	}

	set summary [list]
	foreach player [::blackjack::get_players] {
		set player_summary [split $player]
		foreach hand [::blackjack::get_hands $player] {
			if {[::blackjack::has_surrendered $player $hand]} {
				continue
			}

			set player_total [::blackjack::count [::blackjack::get_player_cards $player $hand]]
			switch -- [::blackjack::hand $house_total] {
				bust {
					switch -- [::blackjack::hand $player_total] {
						safe { set b_ratio 1 }
						blackjack { set b_ratio 1.5 }
						bust { set b_ratio -1 }
					}
				}

				blackjack {
					switch -- [::blackjack::hand $player_total] {
						safe { set b_ratio -1 }
						blackjack { set b_ratio 0 }
						bust { set b_ratio -1 }
					}
				}

				safe {
					switch -- [::blackjack::hand $player_total] {
						safe {
							if {$house_total > $player_total} {
								set b_ratio -1
							} elseif {$house_total < $player_total} {
								set b_ratio 1
							} else {
								set b_ratio 0
							}
						}
						blackjack { set b_ratio 1.5 }
						bust { set b_ratio -1 }
					}
				}	
			}

			set winnings [::blackjack::balance $player $hand $b_ratio $i_ratio]
			set balance [::blackjack::get_balance $player]
			lappend player_summary [list $winnings $player_total]
		}
		lappend player_summary [::blackjack::get_balance $player]
		lappend summary $player_summary
	}
	::blackjack::print_summary $summary

	::blackjack::retire_cards

	if {[::blackjack::is_game_active]} {
		::blackjack::set_hand_active 0
		utimer $::blackjack::delay ::blackjack::main
	}
}

proc ::blackjack::hand {hand} {
	if {$::blackjack::debug} { putlog "::hand $hand" }
	if {$hand > 21} {
		return "bust"
	}

	if {$hand == 21} {
		return "blackjack"
	}

	return "safe"
}

proc ::blackjack::offer_insurance {} {
	if {$::blackjack::debug} { putlog "::offer_insurance" }
	if {[string match [lindex [lindex [::blackjack::get_house_cards] 0] 0] {A}]} {
		# no one has enough money to buy insurance
		if {[::blackjack::all_insured]} {
			return 0
		}
		::blackjack::set_insurable 1
		::blackjack::msg "Does anyone want insurance?"
		set ::blackjack::insurance_id [utimer $::blackjack::insurance_time ::blackjack::close_insurance]
		return 1
	}

	return 0
}

proc ::blackjack::close_insurance {} {
	if {[lsearch -index 2 [utimers] $::blackjack::insurance_id] != -1} {
		killutimer $::blackjack::insurance_id
	}

	set ::blackjack::insurance_id {}
	if {![::blackjack::is_game_active] || ![::blackjack::is_insurable]} {
		return
	}

	::blackjack::set_insurable 0

	if {[llength [set players_insured [::blackjack::players_insured]]]} {
		::blackjack::msg "Insured: [join $players_insured {, }]"
	}

	::blackjack::next
}

proc ::blackjack::balance {player hand b_multiplier {i_multiplier 0}} {
	if {$::blackjack::debug} { putlog "::balance $player $b_multiplier $i_multiplier" }
	set balance [::blackjack::get_balance $player]
	set bet [::blackjack::get_bet $player]

	if {[::blackjack::is_doubled $player $hand]} {
		set b_multiplier [expr {$b_multiplier * 2}]
	}
	set winnings [expr {$bet * $b_multiplier}]
	if {[::blackjack::is_insured $player]} {
		set winnings [expr {$winnings + ($bet * 0.5 * $i_multiplier)}]
	}

	::blackjack::set_balance $player [expr {$balance + $winnings}]

	return $winnings
}

proc ::blackjack::get_active_player {} {
	if {$::blackjack::active_player == -1} {
		return {}
	}

	return [lindex [::blackjack::get_players] $::blackjack::active_player]
}

proc ::blackjack::is_valid_bet {bet} {
	if {![string is integer $bet]} {
		return 0
	}

	return [expr $bet >= $::blackjack::min && $bet <= $::blackjack::max]
}

proc ::blackjack::card {} {
	if {![llength $::blackjack::deck]} {
		::blackjack::set_deck
	}

	set card [lindex $::blackjack::deck end]
	set ::blackjack::deck [lreplace $::blackjack::deck end end]

	return $card
}

# Durstenfeld implementation of Fisher-Yates shuffle
proc ::blackjack::shuffle {deck} {
	for {set i [llength $deck]} {$i > 1} {incr i -1} {
		set j [expr {int(rand() * $i)}]
		set temp [lindex $deck $j]
		set switch_index [expr $i - 1]
		lset deck $j [lindex $deck $switch_index]
		lset deck $switch_index $temp
	}

	return $deck
} 

proc ::blackjack::deck {n} {
	set deck [list]
	for {set i 0} {$i < $n} {incr i} {
		foreach suit [list C D H S] {
			foreach card [list 2 3 4 5 6 7 8 9 10 J Q K A] {
				lappend deck [list $card $suit]
			}
		}

		set deck [::blackjack::shuffle $deck]
	}

	return $deck
}

proc ::blackjack::count {cards} {
	if {$::blackjack::debug} { putlog "::count $cards" }
	set aces 0
	set total 0
	foreach card $cards {
		set card [lindex $card 0]
		if {[string match {A} $card]} {
			incr aces
			continue
		}

		if {[lsearch [list J Q K] $card] != -1} {
			set card 10
		}

		incr total $card
	}

	if {$aces} {
		set max [expr {$aces * 11 + $total}]
		for {set i 0} {$i < $aces} {incr i} {
			if {[set soft [expr {$max - $i * 10}]] <= 21} {
				return $soft
			}
		}

		return [expr $total + $aces]
	}

	return $total
}

proc ::blackjack::print_cards {cards} {
	set printable_cards [list]
	foreach card $cards {
		set value [lindex $card 0]
		set suit [::blackjack::get_suit [lindex $card 1]]
		lappend printable_cards "${value}${suit}"
	}

	return [join $printable_cards {, }]
}

# take house cards & cards of all players and add them to retired_deck
# so that they may be reshuffled later
proc ::blackjack::retire_cards {} {
	lappend ::blackjack::deck_retired {*}[dict get $::blackjack::house cards]
	foreach player [::blackjack::get_players] {
		foreach hand [::blackjack::get_hands $player] {
			lappend ::blackjack::deck_retired {*}[::blackjack::get_player_cards $player $hand]
		}
	}
}

proc ::blackjack::get_suit {suit} {
	switch -- $suit {
		C { return \u2663 }
		S { return \u2660 }
		D { return \u2666 }
		H { return \u2665 }
		default { return {?} }
	}
}

proc ::blackjack::save_players {type} {
	if {[catch {open $::blackjack::file w} fid]} {
		return
	}

	foreach player [dict keys $::blackjack::players] {
		puts $fid [list $player [::blackjack::get_balance $player] [::blackjack::get_bought $player]]
	}

	close $fid
}

proc ::blackjack::load_players {} {
	if {[catch {open $::blackjack::file r} fid]} {
		return
	}

	while {[gets $fid data] >= 0} {
		if {[llength $data] < 2} {
			continue
		}

		::blackjack::set_balance [lindex $data 0] [lindex $data 1]
		::blackjack::set_bought [lindex $data 0] [lindex $data 2]
	}

	close $fid
}

proc ::blackjack::can_double {player} {
	set total [::blackjack::count [::blackjack::get_player_cards $player]]
	return [expr {$total >= 9 && $total <= 11}]
}

proc ::blackjack::is_game_active {} {
	return $::blackjack::is_game_active
}

proc ::blackjack::set_game_active {status} {
	set ::blackjack::is_game_active $status
}

proc ::blackjack::is_hand_active {} {
	return $::blackjack::is_hand_active
}

proc ::blackjack::set_hand_active {status} {
	set ::blackjack::is_hand_active $status
}

proc ::blackjack::get_balance {player} {
	if {![dict exists $::blackjack::players $player balance]} {
		return 0
	}

	return [dict get $::blackjack::players $player balance]
}

proc ::blackjack::get_bought {player} {
	if {![dict exists $::blackjack::players $player bought]} {
		return 0
	}

	return [dict get $::blackjack::players $player bought]
}

proc ::blackjack::has_chips {player} {
	return [expr {[::blackjack::get_balance $player] >= $::blackjack::min}]
}

proc ::blackjack::has_own_bet {player} {
	return [::blackjack::check_balance $player [::blackjack::get_bet $player]]
}

proc ::blackjack::set_balance {player balance} {
	dict set ::blackjack::players $player balance $balance
}

proc ::blackjack::set_bought {player bought} {
	dict set ::blackjack::players $player bought $bought
}

proc ::blackjack::update_bets {} {
	foreach player [::blackjack::get_players] {
		if {[dict exists $::blackjack::players $player next_bet]} {
			dict set ::blackjack::players $player bet [dict get $::blackjack::players $player next_bet]
			dict unset ::blackjack::players $player next_bet
		}
	}
}

proc ::blackjack::is_insurable {} {
	return $::blackjack::can_insure
}

proc ::blackjack::set_insurable {status} {
	set ::blackjack::can_insure $status
}

proc ::blackjack::has_surrendered {player {hand {}}} {
	if {[string match $hand {}]} {
		set hand [::blackjack::get_active_hand $player]
	}

	return [dict exists $::blackjack::players $player hand $hand surrendered]
}

proc ::blackjack::set_surrendered {player} {
	dict set ::blackjack::players $player hand [::blackjack::get_active_hand $player] surrendered 1
}

proc ::blackjack::get_house_cards {} {
	if {$::blackjack::debug} { putlog "::get_house_cards" }
	return [dict get $::blackjack::house cards]
}

proc ::blackjack::get_player_cards {player {hand {}}} {
	if {$::blackjack::debug} { putlog "::get_player_cards $player" }
	if {[string match $hand {}]} {
		set hand [::blackjack::get_active_hand $player]
	}

	return [dict get $::blackjack::players $player hand $hand cards]
}

proc ::blackjack::is_sitting {player} {
	return [expr [lsearch [::blackjack::get_players] $player] != -1]
}

proc ::blackjack::is_waiting {player} {
	return [expr [lsearch $::blackjack::players_waiting $player] != -1]
}

proc ::blackjack::is_insured {player} {
	return [dict exists $::blackjack::players $player insured]
}

# check if a player has sufficient balance to purchase insurance
proc ::blackjack::may_insure {player} {
	return [::blackjack::check_balance $player [expr {[::blackjack::get_bet $player] * 1.5}]]
}

# check if all players have either bought insurance or are unable to do so
proc ::blackjack::all_insured {} {
	set insurable 0
	foreach player [::blackjack::get_players] {
		if {[::blackjack::may_insure $player]} {
			incr insurable
		}
	}

	return [expr [llength [::blackjack::players_insured]] == $insurable]
}

proc ::blackjack::set_insured {player} {
	dict set ::blackjack::players $player insured 1
}

proc ::blackjack::is_doubled {player {hand {}}} {
	if {[string match $hand {}]} {
		set hand [::blackjack::get_active_hand $player]
	}

	return [dict exists $::blackjack::players $player hand $hand doubled]
}

proc ::blackjack::set_doubled {player} {
	dict set ::blackjack::players $player hand [::blackjack::get_active_hand $player] doubled 1
}

proc ::blackjack::players_insured {} {
	set players_insured [list]
	foreach player [::blackjack::get_players] {
		if {[::blackjack::is_insured $player]} {
			lappend players_insured $player
		}
	}

	return $players_insured
}

proc ::blackjack::has_profile {player} {
	return [dict exists $::blackjack::players $player]
}

proc ::blackjack::get_players {} {
	return $::blackjack::players_table
}

proc ::blackjack::set_players {players} {
	set ::blackjack::players_table $players
}

proc ::blackjack::check_balance {player bet} {
	return [expr [::blackjack::get_balance $player] >= $bet]
}

proc ::blackjack::is_active_player {player} {
	return [string match [::blackjack::get_active_player] $player]
}

proc ::blackjack::wants_to_stand {player} {
	return [dict exists $::blackjack::players $player stand]
}

proc ::blackjack::get_bet {player} {
	return [dict get $::blackjack::players $player bet]
}

proc ::blackjack::dollars {amount} {
	if {$amount > 0} {
		return "\00309\$[format %.2f $amount]\003"
	} elseif {$amount < 0} {
		return "\00304\$[format %.2f [expr $amount * -1]]\003"
	} else {
		return "\00311\$[format %.2f $amount]\003"
	}
}

proc ::blackjack::print_summary {summary} {
	if {$::blackjack::compressed} {
		set str [list]
		foreach line $summary {
			set hands [list]
			foreach hand [lrange $line 1 end-1] {
				set amount [lindex $hand 0]
				set total [lindex $hand 1]
				if {$amount > 0} {
					lappend hands "won [::blackjack::dollars $amount] on $total"
				} elseif {$amount < 0} {
					lappend hands "lost [::blackjack::dollars $amount] on $total"
				} else {
					lappend hands "pushed on $total"
				}
			}
			lappend str "[lindex $line 0]: [join $hands {, }] ([::blackjack::dollars [lindex $line end]])"
		}
		::blackjack::msg [join $str {, }]
	} else {
		foreach line $summary {
			::blackjack::msg $line
		}
	}
}

# output to server bypassing msgqueue
proc ::blackjack::putnow {args} {
  putdccraw 0 [expr [string length [lindex $args 0]] +1] "[lindex $args 0]\n"
}

# split lines into list of ~max for output
proc ::blackjack::split_line {max str} {
	set last [expr {[string length $str] -1}]
	set start 0
	set end [expr {$max -1}]

	set lines []

	while {$start <= $last} {
		if {$last >= $end} {
			set end [string last { } $str $end]
		}

		lappend lines [string trim [string range $str $start $end]]
		set start $end
		set end [expr {$start + $max}]
	}

	return $lines
}

::blackjack::load_players
putlog "blackjack.tcl v $::blackjack::version loaded (c) tbalboa, horgh 2010"
