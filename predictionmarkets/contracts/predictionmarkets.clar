;; Prediction Markets - Decentralized Forecasting Platform
;; Create, trade, and resolve prediction markets on future events

;; Constants
(define-constant contract-owner tx-sender)
(define-constant err-owner-only (err u400))
(define-constant err-not-authorized (err u401))
(define-constant err-market-not-found (err u402))
(define-constant err-invalid-amount (err u403))
(define-constant err-market-closed (err u404))
(define-constant err-already-resolved (err u405))
(define-constant err-resolution-too-early (err u406))
(define-constant err-not-resolver (err u407))
(define-constant err-already-claimed (err u408))
(define-constant err-no-winnings (err u409))
(define-constant err-slippage-exceeded (err u410))
(define-constant err-markets-paused (err u411))
(define-constant err-invalid-deadline (err u412))
(define-constant err-already-voted (err u413))

;; Market status
(define-constant status-trading u1)
(define-constant status-resolved u2)

;; Fee constants (basis points)
(define-constant trading-fee u50) ;; 0.5%

;; Data Variables
(define-data-var markets-paused bool false)
(define-data-var total-markets-created uint u0)
(define-data-var total-volume-traded uint u0)
(define-data-var total-markets-resolved uint u0)

;; Data Maps

;; Market storage
(define-map markets
  uint
  {
    creator: principal,
    question: (string-ascii 500),
    deadline: uint,
    yes-pool: uint,
    no-pool: uint,
    status: uint,
    outcome: (optional bool),
    resolved-at: (optional uint),
    created-at: uint
  }
)

;; User positions
(define-map positions
  { user: principal, market-id: uint }
  {
    yes-shares: uint,
    no-shares: uint,
    claimed: bool
  }
)

;; Resolvers
(define-map resolvers principal bool)

;; Resolver votes
(define-map votes
  { resolver: principal, market-id: uint }
  bool
)

;; Vote tallies
(define-map tallies
  uint
  {
    yes-votes: uint,
    no-votes: uint
  }
)

;; Private Functions

(define-private (is-contract-owner)
  (is-eq tx-sender contract-owner)
)

(define-private (get-position (user principal) (market-id uint))
  (default-to
    { yes-shares: u0, no-shares: u0, claimed: false }
    (map-get? positions { user: user, market-id: market-id })
  )
)

(define-private (get-tally (market-id uint))
  (default-to
    { yes-votes: u0, no-votes: u0 }
    (map-get? tallies market-id)
  )
)

;; Calculate shares from STX using constant product AMM
(define-private (calculate-buy-shares (stx-in uint) (pool-buy uint) (pool-sell uint))
  (let
    (
      (fee (/ (* stx-in trading-fee) u10000))
      (stx-after-fee (- stx-in fee))
      (numerator (* stx-after-fee pool-sell))
      (denominator (+ pool-buy stx-after-fee))
    )
    (if (is-eq denominator u0) u0 (/ numerator denominator))
  )
)

;; Calculate STX from shares
(define-private (calculate-sell-stx (shares uint) (pool-shares uint) (pool-stx uint))
  (let
    (
      (numerator (* shares pool-stx))
      (denominator (+ pool-shares shares))
      (stx-out (if (is-eq denominator u0) u0 (/ numerator denominator)))
      (fee (/ (* stx-out trading-fee) u10000))
    )
    (if (> stx-out fee) (- stx-out fee) u0)
  )
)

;; Public Functions

;; Create prediction market
(define-public (create-market (question (string-ascii 500)) (deadline uint) (yes-liq uint) (no-liq uint))
  (let
    (
      (market-id (var-get total-markets-created))
      (creator tx-sender)
      (total (+ yes-liq no-liq))
    )
    (asserts! (not (var-get markets-paused)) err-markets-paused)
    (asserts! (> (len question) u0) err-invalid-amount)
    (asserts! (> deadline stacks-block-height) err-invalid-deadline)
    (asserts! (>= yes-liq u10000000) err-invalid-amount)
    (asserts! (>= no-liq u10000000) err-invalid-amount)
    
    (try! (stx-transfer? total creator (as-contract tx-sender)))
    
    (map-set markets market-id
      {
        creator: creator,
        question: question,
        deadline: deadline,
        yes-pool: yes-liq,
        no-pool: no-liq,
        status: status-trading,
        outcome: none,
        resolved-at: none,
        created-at: stacks-block-height
      }
    )
    
    (map-set positions { user: creator, market-id: market-id }
      { yes-shares: yes-liq, no-shares: no-liq, claimed: false }
    )
    
    (var-set total-markets-created (+ market-id u1))
    (ok market-id)
  )
)

;; Buy YES shares
(define-public (buy-yes (market-id uint) (stx-amount uint) (min-shares uint))
  (let
    (
      (market (unwrap! (map-get? markets market-id) err-market-not-found))
      (buyer tx-sender)
      (yes-pool (get yes-pool market))
      (no-pool (get no-pool market))
      (shares (calculate-buy-shares stx-amount no-pool yes-pool))
      (position (get-position buyer market-id))
    )
    (asserts! (not (var-get markets-paused)) err-markets-paused)
    (asserts! (is-eq (get status market) status-trading) err-market-closed)
    (asserts! (>= shares min-shares) err-slippage-exceeded)
    
    (try! (stx-transfer? stx-amount buyer (as-contract tx-sender)))
    
    (map-set markets market-id
      (merge market {
        yes-pool: (+ yes-pool shares),
        no-pool: (- no-pool shares)
      })
    )
    
    (map-set positions { user: buyer, market-id: market-id }
      (merge position { yes-shares: (+ (get yes-shares position) shares) })
    )
    
    (var-set total-volume-traded (+ (var-get total-volume-traded) stx-amount))
    (ok shares)
  )
)

;; Buy NO shares
(define-public (buy-no (market-id uint) (stx-amount uint) (min-shares uint))
  (let
    (
      (market (unwrap! (map-get? markets market-id) err-market-not-found))
      (buyer tx-sender)
      (yes-pool (get yes-pool market))
      (no-pool (get no-pool market))
      (shares (calculate-buy-shares stx-amount yes-pool no-pool))
      (position (get-position buyer market-id))
    )
    (asserts! (not (var-get markets-paused)) err-markets-paused)
    (asserts! (is-eq (get status market) status-trading) err-market-closed)
    (asserts! (>= shares min-shares) err-slippage-exceeded)
    
    (try! (stx-transfer? stx-amount buyer (as-contract tx-sender)))
    
    (map-set markets market-id
      (merge market {
        yes-pool: (- yes-pool shares),
        no-pool: (+ no-pool shares)
      })
    )
    
    (map-set positions { user: buyer, market-id: market-id }
      (merge position { no-shares: (+ (get no-shares position) shares) })
    )
    
    (var-set total-volume-traded (+ (var-get total-volume-traded) stx-amount))
    (ok shares)
  )
)

;; Sell YES shares
(define-public (sell-yes (market-id uint) (shares uint) (min-stx uint))
  (let
    (
      (market (unwrap! (map-get? markets market-id) err-market-not-found))
      (seller tx-sender)
      (position (get-position seller market-id))
      (yes-pool (get yes-pool market))
      (no-pool (get no-pool market))
      (stx-out (calculate-sell-stx shares yes-pool no-pool))
    )
    (asserts! (not (var-get markets-paused)) err-markets-paused)
    (asserts! (is-eq (get status market) status-trading) err-market-closed)
    (asserts! (>= (get yes-shares position) shares) err-invalid-amount)
    (asserts! (>= stx-out min-stx) err-slippage-exceeded)
    
    (map-set positions { user: seller, market-id: market-id }
      (merge position { yes-shares: (- (get yes-shares position) shares) })
    )
    
    (map-set markets market-id
      (merge market {
        yes-pool: (- yes-pool shares),
        no-pool: (+ no-pool stx-out)
      })
    )
    
    (try! (as-contract (stx-transfer? stx-out tx-sender seller)))
    (var-set total-volume-traded (+ (var-get total-volume-traded) stx-out))
    (ok stx-out)
  )
)

;; Sell NO shares
(define-public (sell-no (market-id uint) (shares uint) (min-stx uint))
  (let
    (
      (market (unwrap! (map-get? markets market-id) err-market-not-found))
      (seller tx-sender)
      (position (get-position seller market-id))
      (yes-pool (get yes-pool market))
      (no-pool (get no-pool market))
      (stx-out (calculate-sell-stx shares no-pool yes-pool))
    )
    (asserts! (not (var-get markets-paused)) err-markets-paused)
    (asserts! (is-eq (get status market) status-trading) err-market-closed)
    (asserts! (>= (get no-shares position) shares) err-invalid-amount)
    (asserts! (>= stx-out min-stx) err-slippage-exceeded)
    
    (map-set positions { user: seller, market-id: market-id }
      (merge position { no-shares: (- (get no-shares position) shares) })
    )
    
    (map-set markets market-id
      (merge market {
        yes-pool: (+ yes-pool stx-out),
        no-pool: (- no-pool shares)
      })
    )
    
    (try! (as-contract (stx-transfer? stx-out tx-sender seller)))
    (var-set total-volume-traded (+ (var-get total-volume-traded) stx-out))
    (ok stx-out)
  )
)

;; Resolver votes on outcome
(define-public (vote-resolution (market-id uint) (outcome bool))
  (let
    (
      (market (unwrap! (map-get? markets market-id) err-market-not-found))
      (resolver tx-sender)
      (tally (get-tally market-id))
    )
    (asserts! (default-to false (map-get? resolvers resolver)) err-not-resolver)
    (asserts! (>= stacks-block-height (get deadline market)) err-resolution-too-early)
    (asserts! (is-eq (get status market) status-trading) err-already-resolved)
    (asserts! (is-none (map-get? votes { resolver: resolver, market-id: market-id })) err-already-voted)
    
    (map-set votes { resolver: resolver, market-id: market-id } outcome)
    
    (map-set tallies market-id
      (if outcome
        { yes-votes: (+ (get yes-votes tally) u1), no-votes: (get no-votes tally) }
        { yes-votes: (get yes-votes tally), no-votes: (+ (get no-votes tally) u1) }
      )
    )
    
    (ok true)
  )
)

;; Finalize market resolution
(define-public (finalize-market (market-id uint))
  (let
    (
      (market (unwrap! (map-get? markets market-id) err-market-not-found))
      (tally (get-tally market-id))
      (yes-votes (get yes-votes tally))
      (no-votes (get no-votes tally))
      (outcome (> yes-votes no-votes))
    )
    (asserts! (is-contract-owner) err-owner-only)
    (asserts! (is-eq (get status market) status-trading) err-already-resolved)
    (asserts! (>= stacks-block-height (get deadline market)) err-resolution-too-early)
    (asserts! (or (>= yes-votes u2) (>= no-votes u2)) err-invalid-amount)
    
    (map-set markets market-id
      (merge market {
        status: status-resolved,
        outcome: (some outcome),
        resolved-at: (some stacks-block-height)
      })
    )
    
    (var-set total-markets-resolved (+ (var-get total-markets-resolved) u1))
    (ok outcome)
  )
)

;; Claim winnings
(define-public (claim-winnings (market-id uint))
  (let
    (
      (market (unwrap! (map-get? markets market-id) err-market-not-found))
      (claimer tx-sender)
      (position (get-position claimer market-id))
      (outcome (unwrap! (get outcome market) err-already-resolved))
      (winning-shares (if outcome (get yes-shares position) (get no-shares position)))
      (total-pool (+ (get yes-pool market) (get no-pool market)))
      (payout (if (is-eq winning-shares u0) u0 total-pool))
    )
    (asserts! (is-eq (get status market) status-resolved) err-market-closed)
    (asserts! (not (get claimed position)) err-already-claimed)
    (asserts! (> winning-shares u0) err-no-winnings)
    
    (map-set positions { user: claimer, market-id: market-id }
      (merge position { claimed: true })
    )
    
    (try! (as-contract (stx-transfer? payout tx-sender claimer)))
    (ok payout)
  )
)

;; Administrative Functions

(define-public (add-resolver (resolver principal))
  (begin
    (asserts! (is-contract-owner) err-owner-only)
    (map-set resolvers resolver true)
    (ok true)
  )
)

(define-public (remove-resolver (resolver principal))
  (begin
    (asserts! (is-contract-owner) err-owner-only)
    (map-set resolvers resolver false)
    (ok true)
  )
)

(define-public (pause-markets)
  (begin
    (asserts! (is-contract-owner) err-owner-only)
    (var-set markets-paused true)
    (ok true)
  )
)

(define-public (resume-markets)
  (begin
    (asserts! (is-contract-owner) err-owner-only)
    (var-set markets-paused false)
    (ok true)
  )
)

;; Read-Only Functions

(define-read-only (get-market (market-id uint))
  (map-get? markets market-id)
)

(define-read-only (get-user-position (user principal) (market-id uint))
  (get-position user market-id)
)

(define-read-only (get-current-price (market-id uint))
  (match (map-get? markets market-id)
    market (let
      (
        (yes-pool (get yes-pool market))
        (no-pool (get no-pool market))
        (total (+ yes-pool no-pool))
      )
      (ok {
        yes-price: (if (is-eq total u0) u5000 (/ (* yes-pool u10000) total)),
        no-price: (if (is-eq total u0) u5000 (/ (* no-pool u10000) total))
      })
    )
    err-market-not-found
  )
)

(define-read-only (calculate-buy-return (market-id uint) (stx-amount uint) (is-yes bool))
  (match (map-get? markets market-id)
    market (ok (if is-yes
      (calculate-buy-shares stx-amount (get no-pool market) (get yes-pool market))
      (calculate-buy-shares stx-amount (get yes-pool market) (get no-pool market))
    ))
    err-market-not-found
  )
)

(define-read-only (calculate-sell-return (market-id uint) (shares uint) (is-yes bool))
  (match (map-get? markets market-id)
    market (ok (if is-yes
      (calculate-sell-stx shares (get yes-pool market) (get no-pool market))
      (calculate-sell-stx shares (get no-pool market) (get yes-pool market))
    ))
    err-market-not-found
  )
)

(define-read-only (is-resolver (user principal))
  (default-to false (map-get? resolvers user))
)

(define-read-only (get-vote-tally (market-id uint))
  (get-tally market-id)
)

(define-read-only (get-platform-stats)
  {
    total-markets: (var-get total-markets-created),
    resolved-markets: (var-get total-markets-resolved),
    total-volume: (var-get total-volume-traded),
    is-paused: (var-get markets-paused)
  }
)

(define-read-only (get-market-odds (market-id uint))
  (match (map-get? markets market-id)
    market (let
      (
        (yes-pool (get yes-pool market))
        (no-pool (get no-pool market))
        (total (+ yes-pool no-pool))
      )
      (ok (if (is-eq total u0) u50 (/ (* yes-pool u100) total)))
    )
    err-market-not-found
  )
)

(define-read-only (calculate-potential-payout (market-id uint) (user principal))
  (match (map-get? markets market-id)
    market (let
      (
        (position (get-position user market-id))
        (outcome (get outcome market))
        (total-pool (+ (get yes-pool market) (get no-pool market)))
      )
      (ok (match outcome
        resolved-outcome (if resolved-outcome
          (if (> (get yes-shares position) u0) total-pool u0)
          (if (> (get no-shares position) u0) total-pool u0)
        )
        u0
      ))
    )
    err-market-not-found
  )
)

(define-read-only (get-contract-balance)
  (stx-get-balance (as-contract tx-sender))
)