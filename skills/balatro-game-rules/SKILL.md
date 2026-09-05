---
name: balatro-game-rules
description: Vanilla Balatro rules for run flow, poker-hand recognition, scoring semantics, drawing and discarding, Blind resolution, Shop behavior, and economy defaults.
version: 1.0.0
---

# Balatro Game Rules

This document defines vanilla Balatro defaults and core game semantics.

## Rule precedence

Current run values and active effects take precedence over the vanilla defaults in this document.

Use these defaults only when no active rule changes them.

## Goal and Antes

The goal of each round is to earn enough Chips to defeat the current Blind.

A standard run has 8 Antes.

Each Ante normally contains, in order:

1. Small Blind
2. Big Blind
3. Boss Blind

Small Blind and Big Blind may be skipped for their displayed Tags.

Boss Blinds cannot normally be skipped.

Defeating the Boss Blind advances the run to the next Ante.

Beat the Boss Blind of Ante 8 to win the run. After winning, the run may continue in Endless Mode.

Default Blind requirement multipliers are:

- Small Blind: 1x base
- Big Blind: 1.5x base
- ordinary Boss Blind: usually 2x base

Specific Boss Blinds can use different requirements.

Default Blind cash rewards are:

- Small Blind: $3
- Big Blind: $4
- ordinary Boss Blind: $5

Finisher Blinds and other effects may differ.

Use the current Blind's actual requirement, reward, ability, and displayed skip Tag.

## Skipping Blinds

Skipping a Small Blind or Big Blind:

- grants its displayed Tag;
- does not play that Blind;
- does not grant that Blind's normal Cash Out;
- skips the Shop that would have followed that Blind.

Boss Blinds cannot normally be skipped.

Evaluate a skip as a trade between the Tag and everything lost by not playing the Blind, including reward money, interest opportunity, remaining-Hand income, scaling opportunities, and access to the skipped Shop.

## Default run values

Unless modified by the Deck, Stake, Voucher, Joker, Blind, or another effect, a run begins with:

- 4 Hands per round
- 3 Discards per round
- Hand Size 8
- 5 Joker slots
- 2 Consumable slots
- $4

Treat these only as defaults.

## Playing cards

Unless modified by the selected Deck or another effect, the playing deck begins with 52 cards.

There are 4 suits:

- Spades
- Hearts
- Clubs
- Diamonds

Each suit normally contains 13 ranks:

- Ace
- King
- Queen
- Jack
- 10 through 2

Default card Chips when scored:

- 2 through 10: Chips equal to rank
- Jack: 10 Chips
- Queen: 10 Chips
- King: 10 Chips
- Ace: 11 Chips

Jack, Queen, and King are Face Cards.

Ace is not a Face Card.

Enhancements, Editions, Seals, debuffs, and other effects can modify how individual playing cards behave.

## Hands, drawing, and discarding

At the beginning of a normal round, draw cards until the current Hand Size is reached, if enough cards remain in the deck.

### Playing a hand

Normally:

- select 1 to 5 cards;
- play those cards;
- consume 1 Hand;
- resolve hand recognition and scoring;
- if the Blind has not ended, draw until Hand Size is restored, if possible.

Playing fewer than 5 cards is legal unless an effect says otherwise.

Only cards belonging to the recognized poker hand score by default.

Other played cards are unscored unless an effect causes them to score.

Played cards still leave the hand even when they do not score.

### Discarding

Normally:

- select 1 to 5 cards;
- discard those cards;
- consume exactly 1 Discard;
- draw replacement cards until Hand Size is restored, if possible.

Discarding more cards does not consume additional Discards.

### Drawing

If the round continues after normal play or discard resolution, draw from the remaining deck until Hand Size is restored.

No replacement cards are drawn after a hand that ends the round, including a winning hand or a final hand with no Hands remaining.

If fewer cards remain in the deck than are required, draw all remaining cards.

Cards already played or discarded normally remain outside the draw pile for the rest of that round.

Effects may modify draw count, Hand Size, card destinations, or deck behavior.

## Poker hands

Poker-hand recognition uses a fixed hand-type priority.

When the played cards satisfy multiple poker-hand types, the highest-priority matching type is used regardless of:

- its current Hand Level;
- its base Chips or Mult;
- its expected final score.

From highest priority to lowest:

- Flush Five
- Flush House
- Five of a Kind
- Straight Flush
- Four of a Kind
- Full House
- Flush
- Straight
- Three of a Kind
- Two Pair
- Pair
- High Card

The highest-priority match determines the recognized hand, its base Chips and Mult, and its default scoring cards.

The evaluator may retain other matching hand types for effect conditions. For example, a Straight Flush also matches Straight and Flush, a Full House also matches Two Pair, and larger same-rank groups also match smaller same-rank hand types. These secondary matches do not replace the recognized hand.

### Flush Five

Five cards with the same rank and suit.

### Flush House

A Three of a Kind and a Pair, with all cards sharing the same suit.

The pair and Three of a Kind must use different ranks.

### Five of a Kind

Five cards with the same rank.

### Straight Flush

A hand that satisfies both Straight and Flush.

By default this requires 5 consecutive ranks sharing one suit.

### Four of a Kind

Four cards with the same rank.

It may be played with one additional unscored card.

### Full House

A Three of a Kind and a Pair of a different rank.

### Flush

By default, 5 cards sharing the same suit.

### Straight

By default, 5 cards with consecutive ranks.

Ace may be high:

A K Q J 10

or low:

A 2 3 4 5

Ace cannot wrap around.

For example:

K A 2 3 4

is not a Straight.

### Three of a Kind

Three cards with the same rank.

It may be played with up to 2 additional unscored cards.

### Two Pair

Two separate pairs of different ranks.

It may be played with one additional unscored card.

### Pair

Two cards with the same rank.

It may be played with up to 3 additional unscored cards.

### High Card

If no higher-priority poker hand is recognized, the highest-ranked relevant card forms High Card.

Only that card scores by default.

## Royal Flush

Royal Flush is treated as a Straight Flush for Hand Level and scoring purposes.

By default:

A K Q J 10

of the same suit is displayed as a Royal Flush.

Effects that change Straight or Flush recognition can also change which played cards qualify for the Royal Flush display name.

## Secret poker hands

The following poker hands begin hidden from normal Run Info:

- Five of a Kind
- Flush House
- Flush Five

They become visible after they are first played during the run.

Their associated Planet cards can then become available for that run.

## Hand Levels

Each poker-hand type has its own Hand Level and current base Chips and Mult.

Hand Levels do not affect poker-hand recognition priority.

A lower-priority hand with a high level may score far more than a higher-priority hand with a low level.

Use the current poker-hand values when estimating score.

Do not substitute static Level 1 values after a poker hand has been upgraded.

## Scoring

A played hand starts with the recognized poker hand's current base Chips and Mult.

Scoring effects then modify the running Chips and Mult values according to activation order.

The final score gained by the played hand is:

Score gained = floor(final Chips × final Mult)

The floored result is added to the current round score.

Do not assume all Chips are added first and all Mult effects are applied afterward.

Additive and multiplicative effects resolve when their activation occurs, so ordering can change the result.

## Scoring activation order

The complete activation system contains many entity-specific exceptions.

For ordinary scoring reasoning, use this high-level sequence:

1. effects that trigger when the hand is played and before card scoring;
2. played and scored cards, from left to right;
3. effects from cards held in hand, from left to right;
4. independent Joker scoring, with Jokers checked from left to right, followed by eligible held Consumables;
5. applicable final-scoring effects before the score is floored and added, followed by after-hand effects after the score has been added.

Within a scored playing card's activation, its own card properties and effects triggered from that card resolve before moving to the next scored card.

Retriggers repeat the applicable activation of the card or effect.

Specific effects may change retrigger behavior.

## Ordering

Playing cards may be rearranged before playing them when the game permits it.

Cards held in hand may also be rearranged.

Jokers may normally be rearranged.

Left-to-right activation order can change scoring.

In particular, when additive Mult and multiplicative Mult activate during the same stage, applying additive Mult before multiplicative Mult usually produces the larger score.

Therefore card and Joker ordering is a real gameplay decision and must not be treated as cosmetic.

## Round resolution

Score accumulates across Hands during the current Blind.

After the current Hand and its after-hand effects finish resolving, reaching or exceeding the required score ends the round and prevents any additional Hands from being played.

If the required score has not been reached when no Hands remain, the run is lost.

Running out of usable cards can also make the round impossible to continue.

Effects may alter these rules.

## Cash Out

After defeating a Blind, normal Cash Out consists of:

Blind reward

- remaining-Hand income
- interest
- applicable effect-based income

By default:

- each remaining Hand gives $1;
- remaining Discards give $0;
- interest gives $1 for every complete $5 held;
- default interest is capped at $5.

Default interest can therefore be written as:

interest = max(0, min(floor(money / 5), 5))

Interest is based on money already held at the end of the round before normal Cash Out rewards are added.

Therefore the Blind reward and remaining-Hand income from the current Cash Out do not increase that same Cash Out's interest calculation.

Effect-based income counts toward interest only if it has already been added to held money before interest is evaluated; income included in the Cash Out total does not.

Effects can modify interest thresholds, caps, rewards, Hand income, or other Cash Out behavior.

## Shop

A Shop is normally entered after defeating a Blind.

Skipping a Blind also skips the Shop that would have followed it.

By default, a Shop offers:

- 2 random card slots
- 2 initial Booster Pack offers
- up to 1 current unredeemed Voucher offer

The random card slots normally contain Jokers, Tarot cards, or Planet cards according to shop generation rules.

The first Shop visit of a standard run guarantees one normal Buffoon Pack among its Booster Packs.


## Joker slots

The default Joker slot limit is 5.

Normally a Joker requiring a slot cannot be acquired when no compatible Joker slot is available.

Effects can modify Joker slot capacity or cause particular Jokers not to consume a normal slot.

Use the current slot state rather than assuming the default limit.

## Consumable slots

The default Consumable slot limit is 2.

Tarot, Planet, Spectral, and other applicable Consumables generally occupy Consumable slots while held.

Effects may modify slot capacity or acquisition behavior.

Use the current capacity rather than assuming the default limit.

## Booster Packs

Every normal Shop contains 2 Booster Packs by default.

Booster Packs are replaced when entering a new Shop.

Rerolling the random Shop card slots does not reroll Booster Packs.

Opening a Booster Pack follows the rules of that specific pack and its offered entities.

## Vouchers

A normal Shop displays the current unredeemed Voucher offer, if one exists.

Rerolling the Shop does not reroll the Voucher.

The normal Voucher supply refreshes after defeating a Boss Blind.

Voucher effects are passive run upgrades.

## Shop rerolls

Default Shop reroll cost is $5 when entering a Shop.

A reroll:

- replaces all current random card offers and refills the random card slots;
- does not replace Booster Packs;
- does not replace the Voucher.

Each reroll in the same Shop increases the next reroll cost by $1.

For example:

$5 → $6 → $7 → $8 ...

The reroll cost normally resets to $5 upon entering a new Shop.

Effects can modify reroll costs or Shop contents.

## Decision principles implied by the rules

When choosing an action, reason from the current game state rather than from vanilla defaults.

Important consequences include:

- Hand Level does not determine poker-hand recognition priority.
- Unscored played cards still leave the hand.
- One Discard may discard up to 5 cards by default.
- Playing or discarding normally causes replacement cards to be drawn.
- Reaching the Blind requirement ends the round after the current Hand finishes resolving.
- Remaining Hands have economic value at Cash Out.
- Money near an interest threshold has economic value.
- Skipping a Blind also sacrifices its Shop.
- Shop rerolls do not reroll Booster Packs or Vouchers.
- Card and Joker ordering can materially change score.
- Active effects can override any vanilla default in this document.

When an effect and this document disagree, follow the effect.

When a current run value differs from a default in this document, use the current value.
