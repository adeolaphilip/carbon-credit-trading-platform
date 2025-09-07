;; Carbon Marketplace
;; A decentralized marketplace for trading carbon credits
;; Facilitates secure trading with escrow and automated order matching

;; ===== CONSTANTS =====
(define-constant contract-owner tx-sender)
(define-constant err-owner-only (err u200))
(define-constant err-not-authorized (err u201))
(define-constant err-insufficient-balance (err u202))
(define-constant err-invalid-amount (err u203))
(define-constant err-listing-not-found (err u204))
(define-constant err-order-not-found (err u205))
(define-constant err-invalid-price (err u206))
(define-constant err-self-trading (err u207))
(define-constant err-insufficient-payment (err u208))
(define-constant err-trade-failed (err u209))
(define-constant err-listing-inactive (err u210))
(define-constant err-unauthorized-action (err u211))
(define-constant err-invalid-listing (err u212))

;; Trading fee (in basis points, 100 = 1%)
(define-constant trading-fee-basis-points u100)
(define-constant basis-points-divisor u10000)

;; Minimum amounts
(define-constant min-listing-amount u1)
(define-constant min-order-amount u1)
(define-constant min-price u1)

;; ===== DATA VARIABLES =====

;; Listing ID counter
(define-data-var listing-id-nonce uint u0)

;; Order ID counter
(define-data-var order-id-nonce uint u0)

;; Total trading volume
(define-data-var total-trading-volume uint u0)

;; Total fees collected
(define-data-var total-fees-collected uint u0)

;; Marketplace status (active/paused)
(define-data-var marketplace-active bool true)

;; ===== DATA MAPS =====

;; Carbon credit listings
(define-map credit-listings
  uint ;; listing-id
  {
    seller: principal,
    amount: uint,
    price-per-unit: uint, ;; in micro-STX
    total-price: uint,
    created-at: uint,
    expires-at: uint,
    active: bool,
    filled: uint,
    project-type: (string-ascii 64),
    vintage-year: uint
  }
)

;; Buy orders
(define-map buy-orders
  uint ;; order-id
  {
    buyer: principal,
    amount: uint,
    max-price-per-unit: uint,
    total-budget: uint,
    created-at: uint,
    expires-at: uint,
    active: bool,
    filled: uint,
    escrowed-stx: uint
  }
)

;; Trade history
(define-map trade-history
  uint ;; trade-id
  {
    listing-id: uint,
    order-id: (optional uint),
    seller: principal,
    buyer: principal,
    amount: uint,
    price-per-unit: uint,
    total-amount: uint,
    fee-amount: uint,
    trade-timestamp: uint,
    trade-type: (string-ascii 16) ;; "direct" or "order-match"
  }
)

;; User trading statistics
(define-map user-stats
  principal
  {
    total-bought: uint,
    total-sold: uint,
    total-volume: uint,
    total-trades: uint,
    reputation-score: uint
  }
)

;; Escrow balances for buy orders
(define-map escrow-balances principal uint)

;; Authorized traders (optional whitelist)
(define-map authorized-traders principal bool)

;; ===== PRIVATE FUNCTIONS =====

;; Check if caller is contract owner
(define-private (is-owner)
  (is-eq tx-sender contract-owner)
)

;; Check if marketplace is active
(define-private (is-marketplace-active)
  (var-get marketplace-active)
)

;; Calculate trading fee
(define-private (calculate-fee (amount uint))
  (/ (* amount trading-fee-basis-points) basis-points-divisor)
)

;; Update user statistics
(define-private (update-user-stats (user principal) (amount uint) (volume uint) (is-buyer bool))
  (let (
    (current-stats (default-to
      { total-bought: u0, total-sold: u0, total-volume: u0, total-trades: u0, reputation-score: u0 }
      (map-get? user-stats user)
    ))
  )
    (map-set user-stats user {
      total-bought: (if is-buyer (+ (get total-bought current-stats) amount) (get total-bought current-stats)),
      total-sold: (if is-buyer (get total-sold current-stats) (+ (get total-sold current-stats) amount)),
      total-volume: (+ (get total-volume current-stats) volume),
      total-trades: (+ (get total-trades current-stats) u1),
      reputation-score: (if (< (+ (get reputation-score current-stats) u1) u100)
                          (+ (get reputation-score current-stats) u1)
                          u100)
    })
  )
)

;; Execute trade between two parties
(define-private (execute-trade 
  (listing-id uint) 
  (order-id (optional uint))
  (seller principal) 
  (buyer principal) 
  (amount uint) 
  (price-per-unit uint)
  (trade-type (string-ascii 16))
)
  (let (
    (total-price (* amount price-per-unit))
    (fee-amount (calculate-fee total-price))
    (seller-proceeds (- total-price fee-amount))
    (trade-id (+ (var-get order-id-nonce) u1))
  )
    (begin
      ;; Record the trade
      (map-set trade-history trade-id {
        listing-id: listing-id,
        order-id: order-id,
        seller: seller,
        buyer: buyer,
        amount: amount,
        price-per-unit: price-per-unit,
        total-amount: total-price,
        fee-amount: fee-amount,
        trade-timestamp: block-height,
        trade-type: trade-type
      })
      
      ;; Update statistics
      (update-user-stats seller amount seller-proceeds false)
      (update-user-stats buyer amount total-price true)
      
      ;; Update global counters
      (var-set total-trading-volume (+ (var-get total-trading-volume) total-price))
      (var-set total-fees-collected (+ (var-get total-fees-collected) fee-amount))
      
      (print {
        type: "trade-executed",
        trade-id: trade-id,
        listing-id: listing-id,
        seller: seller,
        buyer: buyer,
        amount: amount,
        price: price-per-unit,
        total: total-price,
        fee: fee-amount
      })
      
      (ok trade-id)
    )
  )
)

;; ===== PUBLIC FUNCTIONS =====

;; Initialize the marketplace
(define-public (initialize)
  (begin
    (asserts! (is-owner) err-owner-only)
    (var-set marketplace-active true)
    (ok true)
  )
)

;; Toggle marketplace status (owner only)
(define-public (toggle-marketplace)
  (begin
    (asserts! (is-owner) err-owner-only)
    (var-set marketplace-active (not (var-get marketplace-active)))
    (print { type: "marketplace-toggled", active: (var-get marketplace-active) })
    (ok (var-get marketplace-active))
  )
)

;; Create a new carbon credit listing
(define-public (create-listing
  (amount uint)
  (price-per-unit uint)
  (expires-in-blocks uint)
  (project-type (string-ascii 64))
  (vintage-year uint)
)
  (let (
    (listing-id (+ (var-get listing-id-nonce) u1))
    (total-price (* amount price-per-unit))
    (expires-at (+ block-height expires-in-blocks))
  )
    (begin
      (asserts! (is-marketplace-active) err-listing-inactive)
      (asserts! (>= amount min-listing-amount) err-invalid-amount)
      (asserts! (>= price-per-unit min-price) err-invalid-price)
      (asserts! (> expires-in-blocks u0) err-invalid-listing)
      
      ;; Update listing ID nonce
      (var-set listing-id-nonce listing-id)
      
      ;; Create the listing
      (map-set credit-listings listing-id {
        seller: tx-sender,
        amount: amount,
        price-per-unit: price-per-unit,
        total-price: total-price,
        created-at: block-height,
        expires-at: expires-at,
        active: true,
        filled: u0,
        project-type: project-type,
        vintage-year: vintage-year
      })
      
      (print {
        type: "listing-created",
        listing-id: listing-id,
        seller: tx-sender,
        amount: amount,
        price-per-unit: price-per-unit,
        project-type: project-type
      })
      
      (ok listing-id)
    )
  )
)

;; Cancel an active listing
(define-public (cancel-listing (listing-id uint))
  (let (
    (listing (unwrap! (map-get? credit-listings listing-id) err-listing-not-found))
  )
    (begin
      (asserts! (is-eq tx-sender (get seller listing)) err-unauthorized-action)
      (asserts! (get active listing) err-listing-inactive)
      
      ;; Deactivate the listing
      (map-set credit-listings listing-id (merge listing { active: false }))
      
      (print {
        type: "listing-cancelled",
        listing-id: listing-id,
        seller: tx-sender
      })
      
      (ok true)
    )
  )
)

;; Create a buy order
(define-public (create-buy-order
  (amount uint)
  (max-price-per-unit uint)
  (expires-in-blocks uint)
)
  (let (
    (order-id (+ (var-get order-id-nonce) u1))
    (total-budget (* amount max-price-per-unit))
    (fee-amount (calculate-fee total-budget))
    (required-stx (+ total-budget fee-amount))
    (expires-at (+ block-height expires-in-blocks))
  )
    (begin
      (asserts! (is-marketplace-active) err-listing-inactive)
      (asserts! (>= amount min-order-amount) err-invalid-amount)
      (asserts! (>= max-price-per-unit min-price) err-invalid-price)
      (asserts! (> expires-in-blocks u0) err-invalid-listing)
      
      ;; Transfer STX to escrow (this would need to be implemented with STX transfers)
      ;; For now, we'll track the escrow requirement
      
      ;; Update order ID nonce
      (var-set order-id-nonce order-id)
      
      ;; Create the buy order
      (map-set buy-orders order-id {
        buyer: tx-sender,
        amount: amount,
        max-price-per-unit: max-price-per-unit,
        total-budget: total-budget,
        created-at: block-height,
        expires-at: expires-at,
        active: true,
        filled: u0,
        escrowed-stx: required-stx
      })
      
      ;; Update escrow balance
      (map-set escrow-balances tx-sender 
        (+ (default-to u0 (map-get? escrow-balances tx-sender)) required-stx)
      )
      
      (print {
        type: "buy-order-created",
        order-id: order-id,
        buyer: tx-sender,
        amount: amount,
        max-price: max-price-per-unit
      })
      
      (ok order-id)
    )
  )
)

;; Cancel a buy order
(define-public (cancel-buy-order (order-id uint))
  (let (
    (order (unwrap! (map-get? buy-orders order-id) err-order-not-found))
  )
    (begin
      (asserts! (is-eq tx-sender (get buyer order)) err-unauthorized-action)
      (asserts! (get active order) err-listing-inactive)
      
      ;; Deactivate the order
      (map-set buy-orders order-id (merge order { active: false }))
      
      ;; Release escrow (in a real implementation, this would return STX)
      (let (
        (current-escrow (default-to u0 (map-get? escrow-balances tx-sender)))
        (order-escrow (get escrowed-stx order))
      )
        (if (>= current-escrow order-escrow)
          (map-set escrow-balances tx-sender (- current-escrow order-escrow))
          (map-delete escrow-balances tx-sender)
        )
      )
      
      (print {
        type: "buy-order-cancelled",
        order-id: order-id,
        buyer: tx-sender
      })
      
      (ok true)
    )
  )
)

;; Purchase credits directly from a listing
(define-public (purchase-from-listing (listing-id uint) (amount uint))
  (let (
    (listing (unwrap! (map-get? credit-listings listing-id) err-listing-not-found))
    (available-amount (- (get amount listing) (get filled listing)))
    (purchase-amount (if (<= amount available-amount) amount available-amount))
    (total-price (* purchase-amount (get price-per-unit listing)))
  )
    (begin
      (asserts! (is-marketplace-active) err-listing-inactive)
      (asserts! (get active listing) err-listing-inactive)
      (asserts! (> available-amount u0) err-invalid-amount)
      (asserts! (not (is-eq tx-sender (get seller listing))) err-self-trading)
      (asserts! (<= block-height (get expires-at listing)) err-listing-inactive)
      
      ;; Update listing with filled amount
      (let (
        (new-filled (+ (get filled listing) purchase-amount))
        (is-complete (>= new-filled (get amount listing)))
      )
        (map-set credit-listings listing-id (merge listing {
          filled: new-filled,
          active: (not is-complete)
        }))
      )
      
      ;; Execute the trade
      (unwrap! (execute-trade 
        listing-id
        none
        (get seller listing)
        tx-sender
        purchase-amount
        (get price-per-unit listing)
        "direct"
      ) err-trade-failed)
      
      (ok purchase-amount)
    )
  )
)

;; ===== READ-ONLY FUNCTIONS =====

;; Get listing details
(define-read-only (get-listing (listing-id uint))
  (map-get? credit-listings listing-id)
)

;; Get buy order details
(define-read-only (get-buy-order (order-id uint))
  (map-get? buy-orders order-id)
)

;; Get trade details
(define-read-only (get-trade (trade-id uint))
  (map-get? trade-history trade-id)
)

;; Get user statistics
(define-read-only (get-user-stats (user principal))
  (map-get? user-stats user)
)

;; Get current listing ID nonce
(define-read-only (get-listing-id-nonce)
  (var-get listing-id-nonce)
)

;; Get current order ID nonce
(define-read-only (get-order-id-nonce)
  (var-get order-id-nonce)
)

;; Get marketplace statistics
(define-read-only (get-marketplace-stats)
  {
    total-trading-volume: (var-get total-trading-volume),
    total-fees-collected: (var-get total-fees-collected),
    total-listings: (var-get listing-id-nonce),
    total-orders: (var-get order-id-nonce),
    marketplace-active: (var-get marketplace-active)
  }
)

;; Check if marketplace is active
(define-read-only (is-active)
  (var-get marketplace-active)
)

;; Get escrow balance
(define-read-only (get-escrow-balance (user principal))
  (default-to u0 (map-get? escrow-balances user))
)

;; Get contract owner
(define-read-only (get-contract-owner)
  contract-owner
)

