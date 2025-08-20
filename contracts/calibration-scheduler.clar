;; Calibration Scheduling Contract
;; Manages calibration appointments, maintenance windows, and scheduling history

;; Error constants
(define-constant ERR-NOT-AUTHORIZED (err u200))
(define-constant ERR-APPOINTMENT-NOT-FOUND (err u201))
(define-constant ERR-APPOINTMENT-EXISTS (err u202))
(define-constant ERR-INVALID-INPUT (err u203))
(define-constant ERR-INVALID-STATUS (err u204))
(define-constant ERR-INVALID-DATE (err u205))
(define-constant ERR-EQUIPMENT-NOT-FOUND (err u206))
(define-constant ERR-SLOT-UNAVAILABLE (err u207))

;; Contract owner
(define-constant CONTRACT-OWNER tx-sender)

;; Appointment status constants
(define-constant STATUS-SCHEDULED u1)
(define-constant STATUS-IN-PROGRESS u2)
(define-constant STATUS-COMPLETED u3)
(define-constant STATUS-CANCELLED u4)
(define-constant STATUS-RESCHEDULED u5)

;; Calibration type constants
(define-constant TYPE-ROUTINE u1)
(define-constant TYPE-EMERGENCY u2)
(define-constant TYPE-VERIFICATION u3)
(define-constant TYPE-MAINTENANCE u4)

;; Appointment data structure
(define-map calibration-appointments
  { appointment-id: (string-ascii 50) }
  {
    equipment-id: (string-ascii 50),
    technician: principal,
    scheduled-date: uint,
    scheduled-time: uint,
    duration-hours: uint,
    calibration-type: uint,
    status: uint,
    priority: uint,
    location: (string-ascii 200),
    notes: (string-ascii 500),
    created-by: principal,
    created-at: uint,
    updated-at: uint,
    completed-at: uint
  }
)

;; Equipment calibration history
(define-map equipment-calibration-history
  { equipment-id: (string-ascii 50) }
  { appointment-list: (list 50 (string-ascii 50)) }
)

;; Technician schedule tracking
(define-map technician-schedule
  { technician: principal, date: uint }
  { appointment-list: (list 10 (string-ascii 50)) }
)

;; Daily schedule capacity
(define-map daily-capacity
  { date: uint }
  { total-slots: uint, booked-slots: uint }
)

;; Appointment counter for unique IDs
(define-data-var appointment-counter uint u0)

;; Maximum daily appointments
(define-constant MAX-DAILY-APPOINTMENTS u20)

;; Authorization check
(define-private (is-authorized (caller principal))
  (or (is-eq caller CONTRACT-OWNER)
      (is-eq caller tx-sender)))

;; Validate appointment status
(define-private (is-valid-status (status uint))
  (or (is-eq status STATUS-SCHEDULED)
      (or (is-eq status STATUS-IN-PROGRESS)
          (or (is-eq status STATUS-COMPLETED)
              (or (is-eq status STATUS-CANCELLED)
                  (is-eq status STATUS-RESCHEDULED))))))

;; Validate calibration type
(define-private (is-valid-type (cal-type uint))
  (or (is-eq cal-type TYPE-ROUTINE)
      (or (is-eq cal-type TYPE-EMERGENCY)
          (or (is-eq cal-type TYPE-VERIFICATION)
              (is-eq cal-type TYPE-MAINTENANCE)))))

;; Check if date slot is available
(define-private (is-slot-available (date uint) (technician principal))
  (let ((daily-cap (default-to { total-slots: MAX-DAILY-APPOINTMENTS, booked-slots: u0 }
                               (map-get? daily-capacity { date: date })))
        (tech-schedule (default-to (list)
                                  (get appointment-list (map-get? technician-schedule { technician: technician, date: date })))))
    (and (< (get booked-slots daily-cap) (get total-slots daily-cap))
         (< (len tech-schedule) u8)))) ;; Max 8 appointments per technician per day

;; Schedule calibration appointment
(define-public (schedule-appointment
  (appointment-id (string-ascii 50))
  (equipment-id (string-ascii 50))
  (technician principal)
  (scheduled-date uint)
  (scheduled-time uint)
  (duration-hours uint)
  (calibration-type uint)
  (priority uint)
  (location (string-ascii 200))
  (notes (string-ascii 500)))

  (let ((current-time (unwrap-panic (get-block-info? time (- block-height u1)))))
    ;; Check if appointment already exists
    (asserts! (is-none (map-get? calibration-appointments { appointment-id: appointment-id })) ERR-APPOINTMENT-EXISTS)

    ;; Validate inputs
    (asserts! (> (len appointment-id) u0) ERR-INVALID-INPUT)
    (asserts! (> (len equipment-id) u0) ERR-INVALID-INPUT)
    (asserts! (> scheduled-date current-time) ERR-INVALID-DATE)
    (asserts! (> duration-hours u0) ERR-INVALID-INPUT)
    (asserts! (is-valid-type calibration-type) ERR-INVALID-INPUT)
    (asserts! (<= priority u5) ERR-INVALID-INPUT)

    ;; Check slot availability
    (asserts! (is-slot-available scheduled-date technician) ERR-SLOT-UNAVAILABLE)

    ;; Create appointment
    (map-set calibration-appointments
      { appointment-id: appointment-id }
      {
        equipment-id: equipment-id,
        technician: technician,
        scheduled-date: scheduled-date,
        scheduled-time: scheduled-time,
        duration-hours: duration-hours,
        calibration-type: calibration-type,
        status: STATUS-SCHEDULED,
        priority: priority,
        location: location,
        notes: notes,
        created-by: tx-sender,
        created-at: current-time,
        updated-at: current-time,
        completed-at: u0
      })

    ;; Update equipment calibration history
    (let ((history-list (default-to (list) (get appointment-list (map-get? equipment-calibration-history { equipment-id: equipment-id })))))
      (map-set equipment-calibration-history
        { equipment-id: equipment-id }
        { appointment-list: (unwrap-panic (as-max-len? (append history-list appointment-id) u50)) }))

    ;; Update technician schedule
    (let ((tech-schedule (default-to (list) (get appointment-list (map-get? technician-schedule { technician: technician, date: scheduled-date })))))
      (map-set technician-schedule
        { technician: technician, date: scheduled-date }
        { appointment-list: (unwrap-panic (as-max-len? (append tech-schedule appointment-id) u10)) }))

    ;; Update daily capacity
    (let ((daily-cap (default-to { total-slots: MAX-DAILY-APPOINTMENTS, booked-slots: u0 }
                                 (map-get? daily-capacity { date: scheduled-date }))))
      (map-set daily-capacity
        { date: scheduled-date }
        { total-slots: (get total-slots daily-cap), booked-slots: (+ (get booked-slots daily-cap) u1) }))

    ;; Increment counter
    (var-set appointment-counter (+ (var-get appointment-counter) u1))

    (ok appointment-id)))

;; Update appointment status
(define-public (update-appointment-status
  (appointment-id (string-ascii 50))
  (new-status uint))

  (let ((appointment-data (unwrap! (map-get? calibration-appointments { appointment-id: appointment-id }) ERR-APPOINTMENT-NOT-FOUND))
        (current-time (unwrap-panic (get-block-info? time (- block-height u1)))))

    ;; Check authorization
    (asserts! (or (is-eq tx-sender (get technician appointment-data))
                  (is-eq tx-sender (get created-by appointment-data))
                  (is-eq tx-sender CONTRACT-OWNER)) ERR-NOT-AUTHORIZED)

    ;; Validate status
    (asserts! (is-valid-status new-status) ERR-INVALID-STATUS)

    ;; Update appointment
    (map-set calibration-appointments
      { appointment-id: appointment-id }
      (merge appointment-data {
        status: new-status,
        updated-at: current-time,
        completed-at: (if (is-eq new-status STATUS-COMPLETED) current-time (get completed-at appointment-data))
      }))

    (ok true)))

;; Reschedule appointment
(define-public (reschedule-appointment
  (appointment-id (string-ascii 50))
  (new-date uint)
  (new-time uint)
  (new-technician principal))

  (let ((appointment-data (unwrap! (map-get? calibration-appointments { appointment-id: appointment-id }) ERR-APPOINTMENT-NOT-FOUND))
        (current-time (unwrap-panic (get-block-info? time (- block-height u1)))))

    ;; Check authorization
    (asserts! (or (is-eq tx-sender (get technician appointment-data))
                  (is-eq tx-sender (get created-by appointment-data))
                  (is-eq tx-sender CONTRACT-OWNER)) ERR-NOT-AUTHORIZED)

    ;; Validate new date
    (asserts! (> new-date current-time) ERR-INVALID-DATE)

    ;; Check new slot availability
    (asserts! (is-slot-available new-date new-technician) ERR-SLOT-UNAVAILABLE)

    ;; Update daily capacity for old date (decrease)
    (let ((old-daily-cap (default-to { total-slots: MAX-DAILY-APPOINTMENTS, booked-slots: u1 }
                                     (map-get? daily-capacity { date: (get scheduled-date appointment-data) }))))
      (map-set daily-capacity
        { date: (get scheduled-date appointment-data) }
        { total-slots: (get total-slots old-daily-cap), booked-slots: (- (get booked-slots old-daily-cap) u1) }))

    ;; Update daily capacity for new date (increase)
    (let ((new-daily-cap (default-to { total-slots: MAX-DAILY-APPOINTMENTS, booked-slots: u0 }
                                     (map-get? daily-capacity { date: new-date }))))
      (map-set daily-capacity
        { date: new-date }
        { total-slots: (get total-slots new-daily-cap), booked-slots: (+ (get booked-slots new-daily-cap) u1) }))

    ;; Update appointment
    (map-set calibration-appointments
      { appointment-id: appointment-id }
      (merge appointment-data {
        technician: new-technician,
        scheduled-date: new-date,
        scheduled-time: new-time,
        status: STATUS-RESCHEDULED,
        updated-at: current-time
      }))

    (ok true)))

;; Get appointment details
(define-read-only (get-appointment (appointment-id (string-ascii 50)))
  (map-get? calibration-appointments { appointment-id: appointment-id }))

;; Get equipment calibration history
(define-read-only (get-equipment-history (equipment-id (string-ascii 50)))
  (map-get? equipment-calibration-history { equipment-id: equipment-id }))

;; Get technician schedule for date
(define-read-only (get-technician-schedule (technician principal) (date uint))
  (map-get? technician-schedule { technician: technician, date: date }))

;; Get daily capacity
(define-read-only (get-daily-capacity (date uint))
  (map-get? daily-capacity { date: date }))

;; Get appointment count
(define-read-only (get-appointment-count)
  (var-get appointment-counter))

;; Check if equipment has pending appointments
(define-read-only (has-pending-appointments (equipment-id (string-ascii 50)))
  (match (map-get? equipment-calibration-history { equipment-id: equipment-id })
    history-data
      (let ((appointment-list (get appointment-list history-data)))
        ;; This is simplified - in production would check each appointment status
        (> (len appointment-list) u0))
    false))

;; Get appointments by status
(define-read-only (get-appointment-status (appointment-id (string-ascii 50)))
  (match (map-get? calibration-appointments { appointment-id: appointment-id })
    appointment-data (some (get status appointment-data))
    none))

;; Cancel appointment
(define-public (cancel-appointment
  (appointment-id (string-ascii 50))
  (reason (string-ascii 200)))

  (let ((appointment-data (unwrap! (map-get? calibration-appointments { appointment-id: appointment-id }) ERR-APPOINTMENT-NOT-FOUND))
        (current-time (unwrap-panic (get-block-info? time (- block-height u1)))))

    ;; Check authorization
    (asserts! (or (is-eq tx-sender (get technician appointment-data))
                  (is-eq tx-sender (get created-by appointment-data))
                  (is-eq tx-sender CONTRACT-OWNER)) ERR-NOT-AUTHORIZED)

    ;; Update appointment status
    (map-set calibration-appointments
      { appointment-id: appointment-id }
      (merge appointment-data {
        status: STATUS-CANCELLED,
        notes: reason,
        updated-at: current-time
      }))

    ;; Update daily capacity (decrease booked slots)
    (let ((daily-cap (default-to { total-slots: MAX-DAILY-APPOINTMENTS, booked-slots: u1 }
                                 (map-get? daily-capacity { date: (get scheduled-date appointment-data) }))))
      (map-set daily-capacity
        { date: (get scheduled-date appointment-data) }
        { total-slots: (get total-slots daily-cap), booked-slots: (- (get booked-slots daily-cap) u1) }))

    (ok true)))
