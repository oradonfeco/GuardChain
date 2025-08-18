;; vendor-restriction.clar

;; Title: GuardChain Vendor Restriction Layer
;; Description: Manages approved merchant whitelist and restricted spending for child wallets
;;              Merchants are approved/removed through DAO voting mechanism

;; --- Constants and Error Codes ---

(define-constant ERR-UNAUTHORIZED (err u200))
(define-constant ERR-MERCHANT-NOT-FOUND (err u201))
(define-constant ERR-MERCHANT-ALREADY-EXISTS (err u202))
(define-constant ERR-MERCHANT-NOT-APPROVED (err u203))
(define-constant ERR-INVALID-AMOUNT (err u204))
(define-constant ERR-WALLET-NOT-FOUND (err u205))
(define-constant ERR-INSUFFICIENT-FUNDS (err u206))
(define-constant ERR-PROPOSAL-NOT-FOUND (err u207))
(define-constant ERR-PROPOSAL-EXPIRED (err u208))
(define-constant ERR-ALREADY-VOTED (err u209))
(define-constant ERR-PROPOSAL-NOT-PASSED (err u210))
(define-constant ERR-INVALID-CATEGORY (err u211))

;; --- Constants ---

(define-constant VOTING-PERIOD u1008) ;; ~1 week in blocks (assuming 10min blocks)
(define-constant MIN-VOTES-REQUIRED u3) ;; Minimum votes needed for proposal to pass
(define-constant APPROVAL-THRESHOLD u66) ;; 66% approval needed

;; Merchant Categories
(define-constant CATEGORY-HEALTH u1)
(define-constant CATEGORY-EDUCATION u2)
(define-constant CATEGORY-FOOD u3)
(define-constant CATEGORY-CLOTHING u4)

;; --- State Variables ---

(define-data-var next-merchant-id uint u1)
(define-data-var next-proposal-id uint u1)

;; DAO Members (simplified - in production this would be more sophisticated)
(define-data-var dao-members (list 20 principal) (list))

;; --- Data Maps ---

(define-map merchants
  uint
  {
    merchant-address: principal,
    name: (string-ascii 50),
    category: uint,
    is-approved: bool,
    registration-block: uint
  }
)

(define-map merchant-by-address
  principal
  uint
)

(define-map dao-proposals
  uint
  {
    proposer: principal,
    merchant-id: uint,
    action: (string-ascii 10), ;; "approve" or "remove"
    votes-for: uint,
    votes-against: uint,
    voting-deadline: uint,
    is-executed: bool
  }
)

(define-map proposal-votes
  { proposal-id: uint, voter: principal }
  bool ;; true for yes, false for no
)

;; Track spending per wallet per merchant
(define-map wallet-merchant-spending
  { wallet-id: uint, merchant-id: uint }
  uint
)

;; --- Public Functions ---

;; Register a new merchant (anyone can propose)
(define-public (register-merchant (merchant-address principal) (name (string-ascii 50)) (category uint))
  (let
    (
      (merchant-id (var-get next-merchant-id))
    )
    (begin
      (asserts! (is-none (map-get? merchant-by-address merchant-address)) ERR-MERCHANT-ALREADY-EXISTS)
      (asserts! (and (>= category u1) (<= category u4)) ERR-INVALID-CATEGORY)

      (map-set merchants merchant-id {
        merchant-address: merchant-address,
        name: name,
        category: category,
        is-approved: false,
        registration-block: stacks-block-height
      })

      (map-set merchant-by-address merchant-address merchant-id)
      (var-set next-merchant-id (+ merchant-id u1))
      (ok merchant-id)
    )
  )
)

;; Create DAO proposal to approve/remove merchant
(define-public (create-merchant-proposal (merchant-id uint) (action (string-ascii 10)))
  (let
    (
      (proposal-id (var-get next-proposal-id))
    )
    (begin
      (asserts! (is-some (map-get? merchants merchant-id)) ERR-MERCHANT-NOT-FOUND)
      (asserts! (is-dao-member tx-sender) ERR-UNAUTHORIZED)

      (map-set dao-proposals proposal-id {
        proposer: tx-sender,
        merchant-id: merchant-id,
        action: action,
        votes-for: u0,
        votes-against: u0,
        voting-deadline: (+ stacks-block-height VOTING-PERIOD),
        is-executed: false
      })

      (var-set next-proposal-id (+ proposal-id u1))
      (ok proposal-id)
    )
  )
)

;; Vote on DAO proposal
(define-public (vote-on-proposal (proposal-id uint) (vote bool))
  (match (map-get? dao-proposals proposal-id)
    proposal
    (let
      (
        (vote-key { proposal-id: proposal-id, voter: tx-sender })
      )
      (begin
        (asserts! (is-dao-member tx-sender) ERR-UNAUTHORIZED)
        (asserts! (<= stacks-block-height (get voting-deadline proposal)) ERR-PROPOSAL-EXPIRED)
        (asserts! (is-none (map-get? proposal-votes vote-key)) ERR-ALREADY-VOTED)

        (map-set proposal-votes vote-key vote)

        (if vote
          (map-set dao-proposals proposal-id (merge proposal { votes-for: (+ (get votes-for proposal) u1) }))
          (map-set dao-proposals proposal-id (merge proposal { votes-against: (+ (get votes-against proposal) u1) }))
        )

        (ok true)
      )
    )
    ERR-PROPOSAL-NOT-FOUND
  )
)

;; Execute approved proposal
(define-public (execute-proposal (proposal-id uint))
  (match (map-get? dao-proposals proposal-id)
    proposal
    (begin
      (asserts! (> stacks-block-height (get voting-deadline proposal)) ERR-PROPOSAL-EXPIRED)
      (asserts! (not (get is-executed proposal)) ERR-PROPOSAL-NOT-PASSED)
      
      (let
        (
          (total-votes (+ (get votes-for proposal) (get votes-against proposal)))
          (approval-rate (if (> total-votes u0) 
                          (/ (* (get votes-for proposal) u100) total-votes) 
                          u0))
        )
        (begin
          (asserts! (>= total-votes MIN-VOTES-REQUIRED) ERR-PROPOSAL-NOT-PASSED)
          (asserts! (>= approval-rate APPROVAL-THRESHOLD) ERR-PROPOSAL-NOT-PASSED)

          ;; Execute the proposal
          (if (is-eq (get action proposal) "approve")
            (try! (approve-merchant (get merchant-id proposal)))
            (try! (remove-merchant-approval (get merchant-id proposal)))
          )

          (map-set dao-proposals proposal-id (merge proposal { is-executed: true }))
          (ok true)
        )
      )
    )
    ERR-PROPOSAL-NOT-FOUND
  )
)

;; Restricted spending function - only at approved merchants
(define-public (spend-at-merchant (wallet-id uint) (merchant-id uint) (amount uint))
  (let
    (
      (wallet-details (unwrap! (contract-call? .guard-chain get-wallet-details wallet-id) ERR-WALLET-NOT-FOUND))
      (merchant (unwrap! (map-get? merchants merchant-id) ERR-MERCHANT-NOT-FOUND))
      (current-spending (default-to u0 (map-get? wallet-merchant-spending { wallet-id: wallet-id, merchant-id: merchant-id })))
    )
    (begin
      ;; Verify caller is child or guardian
      (asserts! (or (is-eq (get child wallet-details) tx-sender) 
                    (is-eq (get guardian wallet-details) tx-sender)) ERR-UNAUTHORIZED)
      
      ;; Verify merchant is approved
      (asserts! (get is-approved merchant) ERR-MERCHANT-NOT-APPROVED)
      
      ;; Verify amount is valid
      (asserts! (> amount u0) ERR-INVALID-AMOUNT)
      
      ;; For now, we'll track spending but actual STX transfer would need integration with main contract
      ;; In a full implementation, this would interact with the main wallet balance
      
      (map-set wallet-merchant-spending 
        { wallet-id: wallet-id, merchant-id: merchant-id }
        (+ current-spending amount))
      
      (ok true)
    )
  )
)

;; --- DAO Management Functions ---

(define-public (add-dao-member (new-member principal))
  (let
    (
      (current-members (var-get dao-members))
    )
    (begin
      ;; Simple check - in production this would be more sophisticated
      (asserts! (is-dao-member tx-sender) ERR-UNAUTHORIZED)
      (var-set dao-members (unwrap! (as-max-len? (append current-members new-member) u20) ERR-UNAUTHORIZED))
      (ok true)
    )
  )
)

;; --- Private Functions ---

(define-private (approve-merchant (merchant-id uint))
  (match (map-get? merchants merchant-id)
    merchant
    (begin
      (map-set merchants merchant-id (merge merchant { is-approved: true }))
      (ok true)
    )
    ERR-MERCHANT-NOT-FOUND
  )
)

(define-private (remove-merchant-approval (merchant-id uint))
  (match (map-get? merchants merchant-id)
    merchant
    (begin
      (map-set merchants merchant-id (merge merchant { is-approved: false }))
      (ok true)
    )
    ERR-MERCHANT-NOT-FOUND
  )
)

(define-private (is-dao-member (user principal))
  (is-some (index-of (var-get dao-members) user))
)

;; --- Read-Only Functions ---

(define-read-only (get-merchant-details (merchant-id uint))
  (match (map-get? merchants merchant-id)
    merchant (ok merchant)
    ERR-MERCHANT-NOT-FOUND
  )
)

(define-read-only (get-merchant-by-address (merchant-address principal))
  (match (map-get? merchant-by-address merchant-address)
    merchant-id (get-merchant-details merchant-id)
    ERR-MERCHANT-NOT-FOUND
  )
)

(define-read-only (is-merchant-approved (merchant-id uint))
  (match (map-get? merchants merchant-id)
    merchant (ok (get is-approved merchant))
    ERR-MERCHANT-NOT-FOUND
  )
)

(define-read-only (get-proposal-details (proposal-id uint))
  (match (map-get? dao-proposals proposal-id)
    proposal (ok proposal)
    ERR-PROPOSAL-NOT-FOUND
  )
)

(define-read-only (get-wallet-merchant-spending (wallet-id uint) (merchant-id uint))
  (ok (default-to u0 (map-get? wallet-merchant-spending { wallet-id: wallet-id, merchant-id: merchant-id })))
)

(define-read-only (get-dao-members)
  (ok (var-get dao-members))
)

(define-read-only (get-next-merchant-id)
  (ok (var-get next-merchant-id))
)

(define-read-only (get-next-proposal-id)
  (ok (var-get next-proposal-id))
)
