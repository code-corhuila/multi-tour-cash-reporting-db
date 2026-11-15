-- Read: the refunds of a reservation (plan D-10, AC-D1.20). reservation_id is a plain id of domain 2 (Annex J.3.4).
CREATE INDEX idx_refund_movement_tenant_reservation
    ON cash_reporting.refund_movement (tenant_id, reservation_id);
