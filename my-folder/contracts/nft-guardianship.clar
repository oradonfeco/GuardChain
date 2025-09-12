;; nft-guardianship.clar

;; Title: GuardChain NFT Guardianship Verification
;; Description: Issues verifiable NFT credentials to legal guardians with transferable custody
;;              Integrates with existing guard-chain wallet system for verified guardian management

;; --- Constants and Error Codes ---

(define-constant ERR-UNAUTHORIZED (err u300))
(define-constant ERR-GUARDIAN-NOT-FOUND (err u301))
(define-constant ERR-GUARDIAN-ALREADY-EXISTS (err u302))
(define-constant ERR-INVALID-GUARDIAN-ID (err u303))
(define-constant ERR-NOT-GUARDIAN-OWNER (err u304))
(define-constant ERR-TRANSFER-TO-SELF (err u305))
(define-constant ERR-GUARDIAN-NOT-VERIFIED (err u306))
(define-constant ERR-VERIFICATION-EXPIRED (err u307))
(define-constant ERR-INVALID-VERIFICATION-DATA (err u308))

;; --- Constants ---

(define-constant VERIFICATION-PERIOD u52560) ;; ~1 year in blocks (assuming 10min blocks)
(define-constant CONTRACT-OWNER tx-sender)

;; Guardian Status Types
(define-constant STATUS-PENDING u1)
(define-constant STATUS-VERIFIED u2)
(define-constant STATUS-SUSPENDED u3)
(define-constant STATUS-REVOKED u4)

;; --- State Variables ---

(define-data-var next-guardian-id uint u1)
(define-data-var contract-uri (optional (string-utf8 256)) none)

;; --- Data Maps ---

;; Main guardian registry with NFT-like properties
(define-map guardian-registry
  uint
  {
    owner: principal,
    legal-name: (string-ascii 100),
    verification-hash: (buff 32),
    status: uint,
    issued-at: uint,
    expires-at: uint,
    verified-by: principal,
    metadata-uri: (optional (string-utf8 256))
  }
)

;; Map guardian principal to their guardian ID (for quick lookup)
(define-map principal-to-guardian-id
  principal
  uint
)

;; Track guardian ownership history for transparency
(define-map guardian-ownership-history
  { guardian-id: uint, transfer-index: uint }
  {
    from-owner: (optional principal),
    to-owner: principal,
    transferred-at: uint,
    reason: (string-ascii 100)
  }
)

;; Track transfer counts per guardian ID
(define-map guardian-transfer-count
  uint
  uint
)

;; Authorized verifiers (legal authorities, courts, etc.)
(define-map authorized-verifiers
  principal
  {
    name: (string-ascii 50),
    authority-type: (string-ascii 30),
    authorized-at: uint,
    is-active: bool
  }
)

;; --- NFT Trait Implementation ---

(define-non-fungible-token guardian-nft uint)

;; --- Public Functions ---

;; Issue new guardian NFT credential
(define-public (issue-guardian-credential 
    (guardian-principal principal) 
    (legal-name (string-ascii 100))
    (verification-hash (buff 32))
    (metadata-uri (optional (string-utf8 256))))
  (let
    (
      (guardian-id (var-get next-guardian-id))
      (current-block stacks-block-height)
    )
    (begin
      ;; Only authorized verifiers can issue credentials
      (asserts! (is-authorized-verifier tx-sender) ERR-UNAUTHORIZED)
      
      ;; Check guardian doesn't already have credentials
      (asserts! (is-none (map-get? principal-to-guardian-id guardian-principal)) ERR-GUARDIAN-ALREADY-EXISTS)
      
      ;; Validate input data
      (asserts! (> (len legal-name) u0) ERR-INVALID-VERIFICATION-DATA)
      
      ;; Mint NFT to guardian
      (try! (nft-mint? guardian-nft guardian-id guardian-principal))
      
      ;; Store guardian registry data
      (map-set guardian-registry guardian-id {
        owner: guardian-principal,
        legal-name: legal-name,
        verification-hash: verification-hash,
        status: STATUS-VERIFIED,
        issued-at: current-block,
        expires-at: (+ current-block VERIFICATION-PERIOD),
        verified-by: tx-sender,
        metadata-uri: metadata-uri
      })
      
      ;; Create principal lookup
      (map-set principal-to-guardian-id guardian-principal guardian-id)
      
      ;; Record initial ownership
      (map-set guardian-ownership-history 
        { guardian-id: guardian-id, transfer-index: u0 }
        {
          from-owner: none,
          to-owner: guardian-principal,
          transferred-at: current-block,
          reason: "Initial issuance"
        })
      
      (map-set guardian-transfer-count guardian-id u0)
      (var-set next-guardian-id (+ guardian-id u1))
      
      (ok guardian-id)
    )
  )
)

;; Transfer guardian NFT (custody change)
(define-public (transfer-guardianship 
    (guardian-id uint) 
    (new-guardian principal) 
    (reason (string-ascii 100)))
  (let
    (
      (guardian-data (unwrap! (map-get? guardian-registry guardian-id) ERR-GUARDIAN-NOT-FOUND))
      (current-owner (unwrap! (nft-get-owner? guardian-nft guardian-id) ERR-GUARDIAN-NOT-FOUND))
      (transfer-count (default-to u0 (map-get? guardian-transfer-count guardian-id)))
    )
    (begin
      ;; Verify caller owns the NFT
      (asserts! (is-eq tx-sender current-owner) ERR-NOT-GUARDIAN-OWNER)
      
      ;; Cannot transfer to self
      (asserts! (not (is-eq current-owner new-guardian)) ERR-TRANSFER-TO-SELF)
      
      ;; Verify guardian credential is still valid
      (asserts! (is-eq (get status guardian-data) STATUS-VERIFIED) ERR-GUARDIAN-NOT-VERIFIED)
      (asserts! (< stacks-block-height (get expires-at guardian-data)) ERR-VERIFICATION-EXPIRED)
      
      ;; Transfer NFT
      (try! (nft-transfer? guardian-nft guardian-id current-owner new-guardian))
      
      ;; Update registry owner
      (map-set guardian-registry guardian-id 
        (merge guardian-data { owner: new-guardian }))
      
      ;; Update principal lookup
      (map-delete principal-to-guardian-id current-owner)
      (map-set principal-to-guardian-id new-guardian guardian-id)
      
      ;; Record transfer history
      (map-set guardian-ownership-history 
        { guardian-id: guardian-id, transfer-index: (+ transfer-count u1) }
        {
          from-owner: (some current-owner),
          to-owner: new-guardian,
          transferred-at: stacks-block-height,
          reason: reason
        })
      
      (map-set guardian-transfer-count guardian-id (+ transfer-count u1))
      
      (ok true)
    )
  )
)

;; Renew guardian verification (extend expiry)
(define-public (renew-guardian-verification (guardian-id uint))
  (let
    (
      (guardian-data (unwrap! (map-get? guardian-registry guardian-id) ERR-GUARDIAN-NOT-FOUND))
    )
    (begin
      ;; Only authorized verifiers can renew
      (asserts! (is-authorized-verifier tx-sender) ERR-UNAUTHORIZED)
      
      ;; Verify guardian exists and is verified
      (asserts! (is-eq (get status guardian-data) STATUS-VERIFIED) ERR-GUARDIAN-NOT-VERIFIED)
      
      ;; Extend expiry
      (map-set guardian-registry guardian-id 
        (merge guardian-data { 
          expires-at: (+ stacks-block-height VERIFICATION-PERIOD),
          verified-by: tx-sender
        }))
      
      (ok true)
    )
  )
)

;; Suspend guardian credential (emergency action)
(define-public (suspend-guardian (guardian-id uint))
  (let
    (
      (guardian-data (unwrap! (map-get? guardian-registry guardian-id) ERR-GUARDIAN-NOT-FOUND))
    )
    (begin
      ;; Only authorized verifiers can suspend
      (asserts! (is-authorized-verifier tx-sender) ERR-UNAUTHORIZED)
      
      (map-set guardian-registry guardian-id 
        (merge guardian-data { status: STATUS-SUSPENDED }))
      
      (ok true)
    )
  )
)

;; Revoke guardian credential permanently
(define-public (revoke-guardian (guardian-id uint))
  (let
    (
      (guardian-data (unwrap! (map-get? guardian-registry guardian-id) ERR-GUARDIAN-NOT-FOUND))
    )
    (begin
      ;; Only authorized verifiers can revoke
      (asserts! (is-authorized-verifier tx-sender) ERR-UNAUTHORIZED)
      
      (map-set guardian-registry guardian-id 
        (merge guardian-data { status: STATUS-REVOKED }))
      
      (ok true)
    )
  )
)

;; --- Verifier Management Functions ---

(define-public (add-authorized-verifier 
    (verifier principal) 
    (name (string-ascii 50)) 
    (authority-type (string-ascii 30)))
  (begin
    ;; Only contract owner can add verifiers
    (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-UNAUTHORIZED)
    
    (map-set authorized-verifiers verifier {
      name: name,
      authority-type: authority-type,
      authorized-at: stacks-block-height,
      is-active: true
    })
    
    (ok true)
  )
)

(define-public (deactivate-verifier (verifier principal))
  (let
    (
      (verifier-data (unwrap! (map-get? authorized-verifiers verifier) ERR-UNAUTHORIZED))
    )
    (begin
      ;; Only contract owner can deactivate verifiers
      (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-UNAUTHORIZED)
      
      (map-set authorized-verifiers verifier 
        (merge verifier-data { is-active: false }))
      
      (ok true)
    )
  )
)

;; --- Integration Functions ---

;; Verify guardian for guard-chain integration
(define-public (verify-guardian-for-wallet (guardian-principal principal))
  (match (map-get? principal-to-guardian-id guardian-principal)
    guardian-id
    (match (map-get? guardian-registry guardian-id)
      guardian-data
      (let
        (
          (is-valid (and 
            (is-eq (get status guardian-data) STATUS-VERIFIED)
            (< stacks-block-height (get expires-at guardian-data))))
        )
        (ok { guardian-id: guardian-id, is-valid: is-valid })
      )
      ERR-GUARDIAN-NOT-FOUND
    )
    ERR-GUARDIAN-NOT-FOUND
  )
)

;; --- Private Functions ---

(define-private (is-authorized-verifier (verifier principal))
  (match (map-get? authorized-verifiers verifier)
    verifier-data (get is-active verifier-data)
    false
  )
)

;; --- Read-Only Functions ---

(define-read-only (get-guardian-details (guardian-id uint))
  (match (map-get? guardian-registry guardian-id)
    guardian (ok guardian)
    ERR-GUARDIAN-NOT-FOUND
  )
)

(define-read-only (get-guardian-by-principal (guardian-principal principal))
  (match (map-get? principal-to-guardian-id guardian-principal)
    guardian-id (get-guardian-details guardian-id)
    ERR-GUARDIAN-NOT-FOUND
  )
)

(define-read-only (is-guardian-valid (guardian-id uint))
  (match (map-get? guardian-registry guardian-id)
    guardian-data
    (ok (and 
      (is-eq (get status guardian-data) STATUS-VERIFIED)
      (< stacks-block-height (get expires-at guardian-data))))
    ERR-GUARDIAN-NOT-FOUND
  )
)

(define-read-only (get-guardian-transfer-history (guardian-id uint))
  (let
    (
      (transfer-count (default-to u0 (map-get? guardian-transfer-count guardian-id)))
    )
    (ok {
      total-transfers: transfer-count,
      latest-transfer: (map-get? guardian-ownership-history 
        { guardian-id: guardian-id, transfer-index: transfer-count })
    })
  )
)

(define-read-only (get-verifier-details (verifier principal))
  (match (map-get? authorized-verifiers verifier)
    verifier-data (ok verifier-data)
    ERR-UNAUTHORIZED
  )
)

(define-read-only (get-next-guardian-id)
  (ok (var-get next-guardian-id))
)

;; --- NFT Metadata Functions ---

(define-read-only (get-last-token-id)
  (ok (- (var-get next-guardian-id) u1))
)

(define-read-only (get-token-uri (guardian-id uint))
  (match (map-get? guardian-registry guardian-id)
    guardian-data (ok (get metadata-uri guardian-data))
    ERR-GUARDIAN-NOT-FOUND
  )
)

(define-read-only (get-owner (guardian-id uint))
  (ok (nft-get-owner? guardian-nft guardian-id))
)
