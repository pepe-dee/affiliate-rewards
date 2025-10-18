;; ------------------------------------------------------------
;; Affiliate Rewards Contract - Clarity v2
;; ------------------------------------------------------------
;; - Merchants create affiliate programs (rate in BPS = parts per 10_000)
;; - Merchants fund the contract (merchant balance)
;; - Merchants record purchases -> affiliate balances are credited
;; - Affiliates claim accumulated rewards in STX
;; - Replay protection via purchase-id (buff 32)
;; - Safe accounting: state updated before external transfers
;; ------------------------------------------------------------

;; -------- Errors ----------
(define-constant ERR-UNAUTHORIZED  (err u100))
(define-constant ERR-BAD-ARGS     (err u101))
(define-constant ERR-NOT-FOUND    (err u102))
(define-constant ERR-INSUFFICIENT (err u103))
(define-constant ERR-ALREADY      (err u104))
(define-constant ERR-PAUSED       (err u105))

;; -------- Config / State ----------
(define-data-var owner principal tx-sender)     ;; contract owner (set at deploy)
(define-data-var paused bool false)             ;; emergency pause switch

(define-data-var next-program-id uint u1)       ;; global incremental program id
(define-data-var treasury principal tx-sender)  ;; optional treasury for fees (not used by default)

;; -------- Program storage ----------
;; program: { id, merchant, rate-bps, active }
(define-map programs
  { id: uint }
  {
    merchant: principal,
    rate-bps: uint,
    active: bool
  })

;; merchant pre-funded balances (STX held by contract on behalf of merchant)
(define-map merchant-balances
  { merchant: principal }
  { balance: uint })

;; affiliate balances (accrued commissions)
(define-map affiliate-balances
  { affiliate: principal }
  { balance: uint })

;; processed purchases (prevent replay)
(define-map processed-purchases
  { pid: (buff 32) }
  { processed: bool })

;; -------- Helpers ----------
(define-read-only (is-owner (p principal)) (is-eq p (var-get owner)))
(define-read-only (is-paused) (var-get paused))

(define-read-only (mul-div (x uint) (num uint) (den uint))
  (if (is-eq den u0) u0 (/ (* x num) den)))

(define-read-only (now) burn-block-height)

;; -------- Admin functions ----------
(define-public (set-treasury (who principal))
  (begin
    (asserts! (is-owner tx-sender) ERR-UNAUTHORIZED)
    (var-set treasury who)
    (ok who)))

(define-public (pause)
  (begin
    (asserts! (is-owner tx-sender) ERR-UNAUTHORIZED)
    (var-set paused true)
    (ok true)))

(define-public (unpause)
  (begin
    (asserts! (is-owner tx-sender) ERR-UNAUTHORIZED)
    (var-set paused false)
    (ok true)))

;; -------- Merchant / Program management ----------

;; Create a new affiliate program: rate-bps in [0,10000]
(define-public (create-program (rate-bps uint))
  (begin
    (asserts! (not (is-paused)) ERR-PAUSED)
    (asserts! (<= rate-bps u10000) ERR-BAD-ARGS)

    (let ((id (var-get next-program-id)))
      (map-set programs { id: id }
        {
          merchant: tx-sender,
          rate-bps: rate-bps,
          active: true
        })
      (var-set next-program-id (+ id u1))
      (ok id))))

;; Update program rate or active flag (merchant only)
(define-public (update-program (id uint) (rate-bps uint) (active bool))
  (match (map-get? programs { id: id })
    p
    (begin
      (asserts! (is-eq (get merchant p) tx-sender) ERR-UNAUTHORIZED)
      (asserts! (<= rate-bps u10000) ERR-BAD-ARGS)
      (map-set programs { id: id } (merge p { rate-bps: rate-bps, active: active }))
      (ok true))
    ERR-NOT-FOUND))

;; Fund merchant balance (caller must be merchant) - transfers STX into contract and credits merchant balance
(define-public (fund-merchant)
  (let ((amt (stx-get-balance tx-sender)))
    (begin
      (asserts! (> amt u0) ERR-BAD-ARGS)
      ;; credit balance to caller (tx-sender)
      (let ((prev (default-to u0 (get balance (map-get? merchant-balances { merchant: tx-sender })))))
        (map-set merchant-balances { merchant: tx-sender } { balance: (+ prev amt) })
        (ok (map-get? merchant-balances { merchant: tx-sender }))))))

;; Withdraw merchant leftover balance (merchant only)
(define-public (merchant-withdraw (amount uint))
  (let ((mb? (map-get? merchant-balances { merchant: tx-sender })))
    (match mb?
      mb
      (let ((bal (get balance mb)))
        (asserts! (>= bal amount) ERR-INSUFFICIENT)
        (map-set merchant-balances { merchant: tx-sender } { balance: (- bal amount) })
        (asserts! (is-ok (stx-transfer? amount (as-contract tx-sender) tx-sender)) ERR-INSUFFICIENT)
        (ok true))
      ERR-NOT-FOUND)))

;; -------- Core: record purchase (merchant records a purchase and credits affiliate) ----------
;; - program-id: which program applies
;; - purchase-id: unique buff32 to prevent replay
;; - sale-amount: total sale amount (in micro-STX units) used to compute commission
;; - affiliate: affiliate principal to credit
;; Note: merchant must have funded their balance via fund-merchant before calling this
(define-public (record-purchase (program-id uint) (purchase-id (buff 32)) (sale-amount uint) (affiliate principal))
  (begin
    (asserts! (not (is-paused)) ERR-PAUSED)
    ;; check program
    (match (map-get? programs { id: program-id })
      program
      (begin
        (asserts! (get active program) ERR-BAD-ARGS)
        (asserts! (is-eq (get merchant program) tx-sender) ERR-UNAUTHORIZED)

        ;; prevent replay
        (asserts! (is-none (map-get? processed-purchases { pid: purchase-id })) ERR-ALREADY)

        ;; compute commission
        (let ((rate (get rate-bps program)))
          (let ((commission (mul-div sale-amount rate u10000)))
            (asserts! (> commission u0) ERR-BAD-ARGS)

            ;; ensure merchant has balance
            (let ((mb (default-to { balance: u0 } (map-get? merchant-balances { merchant: tx-sender }))))
              (asserts! (>= (get balance mb) commission) ERR-INSUFFICIENT)

              ;; debit merchant balance, credit affiliate balance, mark purchase processed
              (map-set merchant-balances { merchant: tx-sender } { balance: (- (get balance mb) commission) })

              (let ((aff-prev (default-to u0 (get balance (map-get? affiliate-balances { affiliate: affiliate })))))
                (map-set affiliate-balances { affiliate: affiliate } { balance: (+ aff-prev commission) }))

              (map-set processed-purchases { pid: purchase-id } { processed: true })

              (ok { commission: commission, affiliate: affiliate })))))
      ERR-NOT-FOUND)))

;; -------- Affiliate claim (withdraw accrued rewards) ----------
(define-public (claim)
  (begin
    (asserts! (not (is-paused)) ERR-PAUSED)
    (let ((row (map-get? affiliate-balances { affiliate: tx-sender })))
      (match row
        r
        (let ((bal (get balance r)))
          (asserts! (> bal u0) ERR-INSUFFICIENT)
          ;; update state before external transfer
          (map-set affiliate-balances { affiliate: tx-sender } { balance: u0 })
          (asserts! (is-ok (stx-transfer? bal (as-contract tx-sender) tx-sender)) ERR-INSUFFICIENT)
          (ok bal))
        ERR-NOT-FOUND))))

;; -------- Views ----------
(define-read-only (get-program (id uint))
  (match (map-get? programs { id: id })
    p (ok p)
    ERR-NOT-FOUND))

(define-read-only (merchant-balance (m principal))
  (ok (default-to u0 (get balance (map-get? merchant-balances { merchant: m })))))

(define-read-only (affiliate-balance (a principal))
  (ok (default-to u0 (get balance (map-get? affiliate-balances { affiliate: a })))))

(define-read-only (is-purchase-processed (pid (buff 32)))
  (ok (is-some (map-get? processed-purchases { pid: pid }))))