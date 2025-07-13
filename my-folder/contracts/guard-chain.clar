;; guard-chain.clar

;; Title: GuardChain - Child Welfare & Charity Wallet
;; Description: A smart contract for creating age-locked STX wallets for children,
;;              with funds unlockable at a defined block height or via guardian approval.

;; --- Constants and Error Codes ---

(define-constant ERR-UNAUTHORIZED (err u100))
(define-constant ERR-WALLET-NOT-FOUND (err u101))
(define-constant ERR-INVALID-AMOUNT (err u102))
(define-constant ERR-UNLOCK-HEIGHT-IN-PAST (err u103))
(define-constant ERR-NOT-UNLOCKED-YET (err u104))
(define-constant ERR-ALREADY-UNLOCKED (err u105))
(define-constant ERR-NOT-GUARDIAN (err u106))
(define-constant ERR-ALREADY-APPROVED (err u107))
(define-constant ERR-CANNOT-APPROVE-UNLOCKED (err u108))

;; --- State Variables ---

(define-data-var next-wallet-id uint u1)

(define-map wallets
  uint
  {
    child: principal,
    guardian: principal,
    locked-amount: uint,
    unlock-block-height: uint,
    is-guardian-approved-early-unlock: bool,
    is-unlocked: bool
  }
)

;; --- Public Functions ---

(define-public (create-locked-wallet (child principal) (guardian principal) (unlock-block-height uint) (amount uint))
  (let
    (
      (wallet-id (var-get next-wallet-id))
      (donor tx-sender)
    )
    (begin
      (asserts! (> amount u0) ERR-INVALID-AMOUNT)
      (asserts! (> unlock-block-height stacks-block-height) ERR-UNLOCK-HEIGHT-IN-PAST)
      (try! (stx-transfer? amount donor (as-contract tx-sender)))

      (map-set wallets wallet-id {
        child: child,
        guardian: guardian,
        locked-amount: amount,
        unlock-block-height: unlock-block-height,
        is-guardian-approved-early-unlock: false,
        is-unlocked: false
      })

      (var-set next-wallet-id (+ wallet-id u1))
      (ok wallet-id)
    )
  )
)

(define-public (guardian-approve-early-unlock (wallet-id uint))
  (match (map-get? wallets wallet-id)
    wallet
    (let (
      (w wallet)
    )
      (begin
        (asserts! (is-eq (get guardian w) tx-sender) ERR-NOT-GUARDIAN)
        (asserts! (not (get is-unlocked w)) ERR-CANNOT-APPROVE-UNLOCKED)
        (asserts! (not (get is-guardian-approved-early-unlock w)) ERR-ALREADY-APPROVED)

        (map-set wallets wallet-id (merge w { is-guardian-approved-early-unlock: true }))
        (ok true)
      )
    )
    ERR-WALLET-NOT-FOUND
  )
)

(define-public (withdraw-funds (wallet-id uint))
  (match (map-get? wallets wallet-id)
    wallet
    (let (
      (w wallet)
    )
      (begin
        (asserts! (or (is-eq (get child w) tx-sender) (is-eq (get guardian w) tx-sender)) ERR-UNAUTHORIZED)
        (asserts! (not (get is-unlocked w)) ERR-ALREADY-UNLOCKED)
        (asserts! (or (>= stacks-block-height (get unlock-block-height w)) (get is-guardian-approved-early-unlock w)) ERR-NOT-UNLOCKED-YET)

        (try! (stx-transfer? (get locked-amount w) (as-contract tx-sender) (get child w)))

        (map-set wallets wallet-id (merge w { is-unlocked: true }))
        (ok true)
      )
    )
    ERR-WALLET-NOT-FOUND
  )
)

;; --- Read-Only Functions ---

(define-read-only (get-wallet-details (wallet-id uint))
  (match (map-get? wallets wallet-id)
    wallet (ok wallet)
    ERR-WALLET-NOT-FOUND
  )
)

(define-read-only (is-wallet-unlockable (wallet-id uint))
  (match (map-get? wallets wallet-id)
    wallet
    (ok (or (>= stacks-block-height (get unlock-block-height wallet)) (get is-guardian-approved-early-unlock wallet)))
    ERR-WALLET-NOT-FOUND
  )
)

(define-read-only (get-next-wallet-id)
  (ok (var-get next-wallet-id))
)

(define-read-only (get-contract-balance)
  (ok (stx-get-balance (as-contract tx-sender)))
)
