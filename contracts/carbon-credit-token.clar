;; Carbon Credit Token (CCT)
;; A SIP-010 compliant fungible token for carbon credits trading
;; Each token represents one metric ton of CO2 equivalent offset

;; ===== CONSTANTS =====
(define-constant contract-owner tx-sender)
(define-constant err-owner-only (err u100))
(define-constant err-not-token-owner (err u101))
(define-constant err-insufficient-balance (err u102))
(define-constant err-invalid-amount (err u103))
(define-constant err-not-authorized (err u104))
(define-constant err-token-already-exists (err u105))
(define-constant err-token-not-found (err u106))
(define-constant err-transfer-failed (err u107))
(define-constant err-mint-failed (err u108))
(define-constant err-burn-failed (err u109))

;; Token metadata constants
(define-constant token-name "Carbon Credit Token")
(define-constant token-symbol "CCT")
(define-constant token-decimals u6)
(define-constant token-uri u"https://carbon-credits.org/metadata")

;; ===== DATA MAPS AND VARIABLES =====

;; Token balances for each principal
(define-map token-balances principal uint)

;; Total supply of tokens
(define-data-var token-total-supply uint u0)

;; Authorized minters (can create new carbon credits)
(define-map authorized-minters principal bool)

;; Carbon credit metadata for tracking environmental impact
(define-map credit-metadata
  uint ;; credit-id
  {
    project-name: (string-ascii 128),
    location: (string-ascii 64),
    vintage-year: uint,
    verification-standard: (string-ascii 32),
    co2-amount: uint,
    issuer: principal,
    created-at: uint,
    retired: bool
  }
)

;; Credit ID counter for unique identification
(define-data-var credit-id-nonce uint u0)

;; Retired credits tracking
(define-map retired-credits principal uint)

;; Transfer allowances for spending tokens on behalf of others
(define-map token-allowances 
  { owner: principal, spender: principal } 
  uint
)

;; ===== PRIVATE FUNCTIONS =====

;; Checks if caller is the contract owner
(define-private (is-owner)
  (is-eq tx-sender contract-owner)
)

;; Checks if principal is an authorized minter
(define-private (is-authorized-minter (minter principal))
  (default-to false (map-get? authorized-minters minter))
)

;; Gets the balance of a principal, defaulting to 0
(define-private (get-balance-uint (account principal))
  (default-to u0 (map-get? token-balances account))
)

;; Updates balance after checking for sufficient funds
(define-private (debit-balance (account principal) (amount uint))
  (let ((current-balance (get-balance-uint account)))
    (if (>= current-balance amount)
      (begin
        (map-set token-balances account (- current-balance amount))
        (ok true)
      )
      err-insufficient-balance
    )
  )
)

;; Adds amount to account balance
(define-private (credit-balance (account principal) (amount uint))
  (let ((current-balance (get-balance-uint account)))
    (map-set token-balances account (+ current-balance amount))
    (ok true)
  )
)

;; Internal transfer function
(define-private (transfer-internal (from principal) (to principal) (amount uint))
  (if (> amount u0)
    (begin
      (unwrap! (debit-balance from amount) err-transfer-failed)
      (unwrap! (credit-balance to amount) err-transfer-failed)
      (print {
        type: "transfer",
        from: from,
        to: to,
        amount: amount
      })
      (ok true)
    )
    (ok true)
  )
)

;; ===== PUBLIC FUNCTIONS =====

;; Initialize the contract (called once by owner)
(define-public (initialize)
  (begin
    (asserts! (is-owner) err-owner-only)
    ;; Add the contract owner as the first authorized minter
    (map-set authorized-minters contract-owner true)
    (ok true)
  )
)

;; Add a new authorized minter (only owner can do this)
(define-public (add-minter (new-minter principal))
  (begin
    (asserts! (is-owner) err-owner-only)
    (map-set authorized-minters new-minter true)
    (print { type: "minter-added", minter: new-minter })
    (ok true)
  )
)

;; Remove a minter (only owner can do this)
(define-public (remove-minter (minter principal))
  (begin
    (asserts! (is-owner) err-owner-only)
    (map-delete authorized-minters minter)
    (print { type: "minter-removed", minter: minter })
    (ok true)
  )
)

;; Mint new carbon credit tokens with metadata
(define-public (mint-with-metadata
  (amount uint)
  (recipient principal)
  (project-name (string-ascii 128))
  (location (string-ascii 64))
  (vintage-year uint)
  (verification-standard (string-ascii 32))
  (co2-amount uint)
)
  (let 
    ((credit-id (+ (var-get credit-id-nonce) u1)))
    (begin
      (asserts! (is-authorized-minter tx-sender) err-not-authorized)
      (asserts! (> amount u0) err-invalid-amount)
      
      ;; Update credit ID nonce
      (var-set credit-id-nonce credit-id)
      
      ;; Store credit metadata
      (map-set credit-metadata credit-id {
        project-name: project-name,
        location: location,
        vintage-year: vintage-year,
        verification-standard: verification-standard,
        co2-amount: co2-amount,
        issuer: tx-sender,
        created-at: block-height,
        retired: false
      })
      
      ;; Mint tokens
      (unwrap! (credit-balance recipient amount) err-mint-failed)
      (var-set token-total-supply (+ (var-get token-total-supply) amount))
      
      (print {
        type: "mint",
        credit-id: credit-id,
        amount: amount,
        recipient: recipient,
        project: project-name,
        co2-amount: co2-amount
      })
      
      (ok credit-id)
    )
  )
)

;; Simple mint function for basic token creation
(define-public (mint (amount uint) (recipient principal))
  (begin
    (asserts! (is-authorized-minter tx-sender) err-not-authorized)
    (asserts! (> amount u0) err-invalid-amount)
    
    (unwrap! (credit-balance recipient amount) err-mint-failed)
    (var-set token-total-supply (+ (var-get token-total-supply) amount))
    
    (print {
      type: "simple-mint",
      amount: amount,
      recipient: recipient,
      minter: tx-sender
    })
    
    (ok true)
  )
)

;; Burn tokens (retire carbon credits)
(define-public (burn (amount uint))
  (let ((current-balance (get-balance-uint tx-sender))
        (retired-amount (default-to u0 (map-get? retired-credits tx-sender))))
    (begin
      (asserts! (> amount u0) err-invalid-amount)
      (asserts! (>= current-balance amount) err-insufficient-balance)
      
      ;; Debit balance
      (unwrap! (debit-balance tx-sender amount) err-burn-failed)
      
      ;; Update total supply
      (var-set token-total-supply (- (var-get token-total-supply) amount))
      
      ;; Track retired credits
      (map-set retired-credits tx-sender (+ retired-amount amount))
      
      (print {
        type: "burn",
        amount: amount,
        burner: tx-sender,
        total-retired: (+ retired-amount amount)
      })
      
      (ok true)
    )
  )
)

;; Transfer tokens from sender to recipient
(define-public (transfer (amount uint) (sender principal) (recipient principal) (memo (optional (buff 34))))
  (begin
    (asserts! (is-eq sender tx-sender) err-not-token-owner)
    (asserts! (> amount u0) err-invalid-amount)
    
    (unwrap! (transfer-internal sender recipient amount) err-transfer-failed)
    
    (match memo 
      memo-value (print { type: "transfer-memo" })
      (print { type: "transfer-no-memo" })
    )
    
    (ok true)
  )
)

;; ===== SIP-010 STANDARD FUNCTIONS =====

;; Get token name
(define-read-only (get-name)
  (ok token-name)
)

;; Get token symbol
(define-read-only (get-symbol)
  (ok token-symbol)
)

;; Get token decimals
(define-read-only (get-decimals)
  (ok token-decimals)
)

;; Get balance of an account
(define-read-only (get-balance (account principal))
  (ok (get-balance-uint account))
)

;; Get total token supply
(define-read-only (get-total-supply)
  (ok (var-get token-total-supply))
)

;; Get token URI
(define-read-only (get-token-uri)
  (ok (some token-uri))
)

;; ===== ADDITIONAL READ-ONLY FUNCTIONS =====

;; Get carbon credit metadata
(define-read-only (get-credit-metadata (credit-id uint))
  (map-get? credit-metadata credit-id)
)

;; Get retired credits amount for an account
(define-read-only (get-retired-credits (account principal))
  (default-to u0 (map-get? retired-credits account))
)

;; Check if address is authorized minter
(define-read-only (is-minter (account principal))
  (is-authorized-minter account)
)

;; Get current credit ID nonce
(define-read-only (get-credit-id-nonce)
  (var-get credit-id-nonce)
)

;; Get contract owner
(define-read-only (get-contract-owner)
  contract-owner
)

