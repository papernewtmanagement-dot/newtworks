-- Backfill producer_production from SF Producer Production Report screenshots
-- provided by Peter 2026-07-08. Quarterly totals split evenly across three
-- calendar months for renewal-stack cohort math.
-- Tommy Q2 2025 attributed to June only (start_date 2025-06-02).
-- John Q1 2026 overwrites prior producer_production rows that undercounted premium.

BEGIN;

-- Clear John's slate entirely (all months) — full backfill of his production history through Q2 2026
DELETE FROM producer_production
WHERE team_member_id = 'ea296434-7802-4370-9cb9-f689df722830';

-- Clear Tommy's 2025 (Jun-Dec) + Q2 2026 (Apr-Jun) — preserves Q1 2026 which is verified match
DELETE FROM producer_production
WHERE team_member_id = '893c77db-1d39-4870-8433-434d9ba07b84'
  AND (
    (period_year = 2025 AND period_month >= 6)
    OR (period_year = 2026 AND period_month IN (4, 5, 6))
  );

-- =========================================================================
-- JOHN KOSTOV (id: ea296434-7802-4370-9cb9-f689df722830)
-- =========================================================================

INSERT INTO producer_production (
  agency_id, team_member_id, period_year, period_month, line_of_business,
  policies_issued, premium_issued, premium_type, is_aipp_qualifying,
  source, notes
) VALUES
-- John Q1 2025 (Auto 38/$34,529.67, Fire 17/$29,040.72, Life 10/$5,573.32, Health 3/$421.50)
('126794dd-25ff-47d2-a436-724499733365','ea296434-7802-4370-9cb9-f689df722830',2025,1,'Auto',13,11509.89,'new_business',true,'sf_ppr_2026-07-08_manual','Q1 2025 split /3'),
('126794dd-25ff-47d2-a436-724499733365','ea296434-7802-4370-9cb9-f689df722830',2025,2,'Auto',13,11509.89,'new_business',true,'sf_ppr_2026-07-08_manual','Q1 2025 split /3'),
('126794dd-25ff-47d2-a436-724499733365','ea296434-7802-4370-9cb9-f689df722830',2025,3,'Auto',12,11509.89,'new_business',true,'sf_ppr_2026-07-08_manual','Q1 2025 split /3'),
('126794dd-25ff-47d2-a436-724499733365','ea296434-7802-4370-9cb9-f689df722830',2025,1,'Fire',6,9680.24,'new_business',true,'sf_ppr_2026-07-08_manual','Q1 2025 split /3'),
('126794dd-25ff-47d2-a436-724499733365','ea296434-7802-4370-9cb9-f689df722830',2025,2,'Fire',6,9680.24,'new_business',true,'sf_ppr_2026-07-08_manual','Q1 2025 split /3'),
('126794dd-25ff-47d2-a436-724499733365','ea296434-7802-4370-9cb9-f689df722830',2025,3,'Fire',5,9680.24,'new_business',true,'sf_ppr_2026-07-08_manual','Q1 2025 split /3'),
('126794dd-25ff-47d2-a436-724499733365','ea296434-7802-4370-9cb9-f689df722830',2025,1,'Life',3,1857.77,'new_business',false,'sf_ppr_2026-07-08_manual','Q1 2025 split /3'),
('126794dd-25ff-47d2-a436-724499733365','ea296434-7802-4370-9cb9-f689df722830',2025,2,'Life',3,1857.77,'new_business',false,'sf_ppr_2026-07-08_manual','Q1 2025 split /3'),
('126794dd-25ff-47d2-a436-724499733365','ea296434-7802-4370-9cb9-f689df722830',2025,3,'Life',4,1857.78,'new_business',false,'sf_ppr_2026-07-08_manual','Q1 2025 split /3'),
('126794dd-25ff-47d2-a436-724499733365','ea296434-7802-4370-9cb9-f689df722830',2025,1,'Health',1,140.50,'new_business',false,'sf_ppr_2026-07-08_manual','Q1 2025 split /3'),
('126794dd-25ff-47d2-a436-724499733365','ea296434-7802-4370-9cb9-f689df722830',2025,2,'Health',1,140.50,'new_business',false,'sf_ppr_2026-07-08_manual','Q1 2025 split /3'),
('126794dd-25ff-47d2-a436-724499733365','ea296434-7802-4370-9cb9-f689df722830',2025,3,'Health',1,140.50,'new_business',false,'sf_ppr_2026-07-08_manual','Q1 2025 split /3'),

-- John Q2 2025 (Auto 25/$22,104.40, Fire 23/$22,517.54, Life 7/$2,415.84, Health 3/$953.67)
('126794dd-25ff-47d2-a436-724499733365','ea296434-7802-4370-9cb9-f689df722830',2025,4,'Auto',8,7368.13,'new_business',true,'sf_ppr_2026-07-08_manual','Q2 2025 split /3'),
('126794dd-25ff-47d2-a436-724499733365','ea296434-7802-4370-9cb9-f689df722830',2025,5,'Auto',8,7368.13,'new_business',true,'sf_ppr_2026-07-08_manual','Q2 2025 split /3'),
('126794dd-25ff-47d2-a436-724499733365','ea296434-7802-4370-9cb9-f689df722830',2025,6,'Auto',9,7368.14,'new_business',true,'sf_ppr_2026-07-08_manual','Q2 2025 split /3'),
('126794dd-25ff-47d2-a436-724499733365','ea296434-7802-4370-9cb9-f689df722830',2025,4,'Fire',8,7505.85,'new_business',true,'sf_ppr_2026-07-08_manual','Q2 2025 split /3'),
('126794dd-25ff-47d2-a436-724499733365','ea296434-7802-4370-9cb9-f689df722830',2025,5,'Fire',8,7505.85,'new_business',true,'sf_ppr_2026-07-08_manual','Q2 2025 split /3'),
('126794dd-25ff-47d2-a436-724499733365','ea296434-7802-4370-9cb9-f689df722830',2025,6,'Fire',7,7505.84,'new_business',true,'sf_ppr_2026-07-08_manual','Q2 2025 split /3'),
('126794dd-25ff-47d2-a436-724499733365','ea296434-7802-4370-9cb9-f689df722830',2025,4,'Life',2,805.28,'new_business',false,'sf_ppr_2026-07-08_manual','Q2 2025 split /3'),
('126794dd-25ff-47d2-a436-724499733365','ea296434-7802-4370-9cb9-f689df722830',2025,5,'Life',2,805.28,'new_business',false,'sf_ppr_2026-07-08_manual','Q2 2025 split /3'),
('126794dd-25ff-47d2-a436-724499733365','ea296434-7802-4370-9cb9-f689df722830',2025,6,'Life',3,805.28,'new_business',false,'sf_ppr_2026-07-08_manual','Q2 2025 split /3'),
('126794dd-25ff-47d2-a436-724499733365','ea296434-7802-4370-9cb9-f689df722830',2025,4,'Health',1,317.89,'new_business',false,'sf_ppr_2026-07-08_manual','Q2 2025 split /3'),
('126794dd-25ff-47d2-a436-724499733365','ea296434-7802-4370-9cb9-f689df722830',2025,5,'Health',1,317.89,'new_business',false,'sf_ppr_2026-07-08_manual','Q2 2025 split /3'),
('126794dd-25ff-47d2-a436-724499733365','ea296434-7802-4370-9cb9-f689df722830',2025,6,'Health',1,317.89,'new_business',false,'sf_ppr_2026-07-08_manual','Q2 2025 split /3'),

-- John Q3 2025 (Auto 34/$26,957.23, Fire 27/$27,416.98, Life 6/$5,021.64, Health 1/$135.84)
('126794dd-25ff-47d2-a436-724499733365','ea296434-7802-4370-9cb9-f689df722830',2025,7,'Auto',11,8985.74,'new_business',true,'sf_ppr_2026-07-08_manual','Q3 2025 split /3'),
('126794dd-25ff-47d2-a436-724499733365','ea296434-7802-4370-9cb9-f689df722830',2025,8,'Auto',11,8985.74,'new_business',true,'sf_ppr_2026-07-08_manual','Q3 2025 split /3'),
('126794dd-25ff-47d2-a436-724499733365','ea296434-7802-4370-9cb9-f689df722830',2025,9,'Auto',12,8985.75,'new_business',true,'sf_ppr_2026-07-08_manual','Q3 2025 split /3'),
('126794dd-25ff-47d2-a436-724499733365','ea296434-7802-4370-9cb9-f689df722830',2025,7,'Fire',9,9138.99,'new_business',true,'sf_ppr_2026-07-08_manual','Q3 2025 split /3'),
('126794dd-25ff-47d2-a436-724499733365','ea296434-7802-4370-9cb9-f689df722830',2025,8,'Fire',9,9138.99,'new_business',true,'sf_ppr_2026-07-08_manual','Q3 2025 split /3'),
('126794dd-25ff-47d2-a436-724499733365','ea296434-7802-4370-9cb9-f689df722830',2025,9,'Fire',9,9139.00,'new_business',true,'sf_ppr_2026-07-08_manual','Q3 2025 split /3'),
('126794dd-25ff-47d2-a436-724499733365','ea296434-7802-4370-9cb9-f689df722830',2025,7,'Life',2,1673.88,'new_business',false,'sf_ppr_2026-07-08_manual','Q3 2025 split /3'),
('126794dd-25ff-47d2-a436-724499733365','ea296434-7802-4370-9cb9-f689df722830',2025,8,'Life',2,1673.88,'new_business',false,'sf_ppr_2026-07-08_manual','Q3 2025 split /3'),
('126794dd-25ff-47d2-a436-724499733365','ea296434-7802-4370-9cb9-f689df722830',2025,9,'Life',2,1673.88,'new_business',false,'sf_ppr_2026-07-08_manual','Q3 2025 split /3'),
('126794dd-25ff-47d2-a436-724499733365','ea296434-7802-4370-9cb9-f689df722830',2025,9,'Health',1,135.84,'new_business',false,'sf_ppr_2026-07-08_manual','Q3 2025 — single Health PIF placed in Sep'),

-- John Q4 2025 (Auto 60/$51,448.00, Fire 32/$58,011.16, Life 12/$9,094.20, Health 2/$239.00)
('126794dd-25ff-47d2-a436-724499733365','ea296434-7802-4370-9cb9-f689df722830',2025,10,'Auto',20,17149.33,'new_business',true,'sf_ppr_2026-07-08_manual','Q4 2025 split /3'),
('126794dd-25ff-47d2-a436-724499733365','ea296434-7802-4370-9cb9-f689df722830',2025,11,'Auto',20,17149.33,'new_business',true,'sf_ppr_2026-07-08_manual','Q4 2025 split /3'),
('126794dd-25ff-47d2-a436-724499733365','ea296434-7802-4370-9cb9-f689df722830',2025,12,'Auto',20,17149.34,'new_business',true,'sf_ppr_2026-07-08_manual','Q4 2025 split /3'),
('126794dd-25ff-47d2-a436-724499733365','ea296434-7802-4370-9cb9-f689df722830',2025,10,'Fire',11,19337.05,'new_business',true,'sf_ppr_2026-07-08_manual','Q4 2025 split /3'),
('126794dd-25ff-47d2-a436-724499733365','ea296434-7802-4370-9cb9-f689df722830',2025,11,'Fire',11,19337.05,'new_business',true,'sf_ppr_2026-07-08_manual','Q4 2025 split /3'),
('126794dd-25ff-47d2-a436-724499733365','ea296434-7802-4370-9cb9-f689df722830',2025,12,'Fire',10,19337.06,'new_business',true,'sf_ppr_2026-07-08_manual','Q4 2025 split /3'),
('126794dd-25ff-47d2-a436-724499733365','ea296434-7802-4370-9cb9-f689df722830',2025,10,'Life',4,3031.40,'new_business',false,'sf_ppr_2026-07-08_manual','Q4 2025 split /3'),
('126794dd-25ff-47d2-a436-724499733365','ea296434-7802-4370-9cb9-f689df722830',2025,11,'Life',4,3031.40,'new_business',false,'sf_ppr_2026-07-08_manual','Q4 2025 split /3'),
('126794dd-25ff-47d2-a436-724499733365','ea296434-7802-4370-9cb9-f689df722830',2025,12,'Life',4,3031.40,'new_business',false,'sf_ppr_2026-07-08_manual','Q4 2025 split /3'),
('126794dd-25ff-47d2-a436-724499733365','ea296434-7802-4370-9cb9-f689df722830',2025,10,'Health',1,79.67,'new_business',false,'sf_ppr_2026-07-08_manual','Q4 2025 split /3'),
('126794dd-25ff-47d2-a436-724499733365','ea296434-7802-4370-9cb9-f689df722830',2025,11,'Health',1,79.67,'new_business',false,'sf_ppr_2026-07-08_manual','Q4 2025 split /3'),
('126794dd-25ff-47d2-a436-724499733365','ea296434-7802-4370-9cb9-f689df722830',2025,12,'Health',0,79.66,'new_business',false,'sf_ppr_2026-07-08_manual','Q4 2025 split /3'),

-- John Q1 2026 OVERWRITE (Auto 52/$46,237.11, Fire 19/$44,648.46, Life 13/$15,565.15, Health 1/$267.24)
('126794dd-25ff-47d2-a436-724499733365','ea296434-7802-4370-9cb9-f689df722830',2026,1,'Auto',17,15412.37,'new_business',true,'sf_ppr_2026-07-08_manual','Q1 2026 split /3 (SF-authoritative overwrite)'),
('126794dd-25ff-47d2-a436-724499733365','ea296434-7802-4370-9cb9-f689df722830',2026,2,'Auto',17,15412.37,'new_business',true,'sf_ppr_2026-07-08_manual','Q1 2026 split /3 (SF-authoritative overwrite)'),
('126794dd-25ff-47d2-a436-724499733365','ea296434-7802-4370-9cb9-f689df722830',2026,3,'Auto',18,15412.37,'new_business',true,'sf_ppr_2026-07-08_manual','Q1 2026 split /3 (SF-authoritative overwrite)'),
('126794dd-25ff-47d2-a436-724499733365','ea296434-7802-4370-9cb9-f689df722830',2026,1,'Fire',6,14882.82,'new_business',true,'sf_ppr_2026-07-08_manual','Q1 2026 split /3 (SF-authoritative overwrite)'),
('126794dd-25ff-47d2-a436-724499733365','ea296434-7802-4370-9cb9-f689df722830',2026,2,'Fire',6,14882.82,'new_business',true,'sf_ppr_2026-07-08_manual','Q1 2026 split /3 (SF-authoritative overwrite)'),
('126794dd-25ff-47d2-a436-724499733365','ea296434-7802-4370-9cb9-f689df722830',2026,3,'Fire',7,14882.82,'new_business',true,'sf_ppr_2026-07-08_manual','Q1 2026 split /3 (SF-authoritative overwrite)'),
('126794dd-25ff-47d2-a436-724499733365','ea296434-7802-4370-9cb9-f689df722830',2026,1,'Life',4,5188.38,'new_business',false,'sf_ppr_2026-07-08_manual','Q1 2026 split /3 (SF-authoritative overwrite)'),
('126794dd-25ff-47d2-a436-724499733365','ea296434-7802-4370-9cb9-f689df722830',2026,2,'Life',4,5188.38,'new_business',false,'sf_ppr_2026-07-08_manual','Q1 2026 split /3 (SF-authoritative overwrite)'),
('126794dd-25ff-47d2-a436-724499733365','ea296434-7802-4370-9cb9-f689df722830',2026,3,'Life',5,5188.39,'new_business',false,'sf_ppr_2026-07-08_manual','Q1 2026 split /3 (SF-authoritative overwrite)'),
('126794dd-25ff-47d2-a436-724499733365','ea296434-7802-4370-9cb9-f689df722830',2026,3,'Health',1,267.24,'new_business',false,'sf_ppr_2026-07-08_manual','Q1 2026 — single Health PIF placed in Mar'),

-- John Q2 2026 (Auto 24/$18,254.40, Fire 22/$21,004.40, Life 3/$1,919.28)
('126794dd-25ff-47d2-a436-724499733365','ea296434-7802-4370-9cb9-f689df722830',2026,4,'Auto',8,6084.80,'new_business',true,'sf_ppr_2026-07-08_manual','Q2 2026 split /3'),
('126794dd-25ff-47d2-a436-724499733365','ea296434-7802-4370-9cb9-f689df722830',2026,5,'Auto',8,6084.80,'new_business',true,'sf_ppr_2026-07-08_manual','Q2 2026 split /3'),
('126794dd-25ff-47d2-a436-724499733365','ea296434-7802-4370-9cb9-f689df722830',2026,6,'Auto',8,6084.80,'new_business',true,'sf_ppr_2026-07-08_manual','Q2 2026 split /3'),
('126794dd-25ff-47d2-a436-724499733365','ea296434-7802-4370-9cb9-f689df722830',2026,4,'Fire',7,7001.46,'new_business',true,'sf_ppr_2026-07-08_manual','Q2 2026 split /3'),
('126794dd-25ff-47d2-a436-724499733365','ea296434-7802-4370-9cb9-f689df722830',2026,5,'Fire',7,7001.47,'new_business',true,'sf_ppr_2026-07-08_manual','Q2 2026 split /3'),
('126794dd-25ff-47d2-a436-724499733365','ea296434-7802-4370-9cb9-f689df722830',2026,6,'Fire',8,7001.47,'new_business',true,'sf_ppr_2026-07-08_manual','Q2 2026 split /3'),
('126794dd-25ff-47d2-a436-724499733365','ea296434-7802-4370-9cb9-f689df722830',2026,4,'Life',1,639.76,'new_business',false,'sf_ppr_2026-07-08_manual','Q2 2026 split /3'),
('126794dd-25ff-47d2-a436-724499733365','ea296434-7802-4370-9cb9-f689df722830',2026,5,'Life',1,639.76,'new_business',false,'sf_ppr_2026-07-08_manual','Q2 2026 split /3'),
('126794dd-25ff-47d2-a436-724499733365','ea296434-7802-4370-9cb9-f689df722830',2026,6,'Life',1,639.76,'new_business',false,'sf_ppr_2026-07-08_manual','Q2 2026 split /3'),

-- =========================================================================
-- TOMMY LYNCH (id: 893c77db-1d39-4870-8433-434d9ba07b84) — start_date 2025-06-02
-- =========================================================================

-- Tommy Q2 2025 → June only (Auto 13/$19,660.81, Fire 9/$8,613.75, Life 3/$1,458.60, Health 5/$697.68)
('126794dd-25ff-47d2-a436-724499733365','893c77db-1d39-4870-8433-434d9ba07b84',2025,6,'Auto',13,19660.81,'new_business',true,'sf_ppr_2026-07-08_manual','Q2 2025 — attributed to June only (start_date 2025-06-02)'),
('126794dd-25ff-47d2-a436-724499733365','893c77db-1d39-4870-8433-434d9ba07b84',2025,6,'Fire',9,8613.75,'new_business',true,'sf_ppr_2026-07-08_manual','Q2 2025 — attributed to June only'),
('126794dd-25ff-47d2-a436-724499733365','893c77db-1d39-4870-8433-434d9ba07b84',2025,6,'Life',3,1458.60,'new_business',false,'sf_ppr_2026-07-08_manual','Q2 2025 — attributed to June only'),
('126794dd-25ff-47d2-a436-724499733365','893c77db-1d39-4870-8433-434d9ba07b84',2025,6,'Health',5,697.68,'new_business',false,'sf_ppr_2026-07-08_manual','Q2 2025 — attributed to June only'),

-- Tommy Q3 2025 (Auto 50/$41,039.96, Fire 28/$26,915.60, Life 3/$2,001.00)
('126794dd-25ff-47d2-a436-724499733365','893c77db-1d39-4870-8433-434d9ba07b84',2025,7,'Auto',17,13679.99,'new_business',true,'sf_ppr_2026-07-08_manual','Q3 2025 split /3'),
('126794dd-25ff-47d2-a436-724499733365','893c77db-1d39-4870-8433-434d9ba07b84',2025,8,'Auto',17,13679.99,'new_business',true,'sf_ppr_2026-07-08_manual','Q3 2025 split /3'),
('126794dd-25ff-47d2-a436-724499733365','893c77db-1d39-4870-8433-434d9ba07b84',2025,9,'Auto',16,13679.98,'new_business',true,'sf_ppr_2026-07-08_manual','Q3 2025 split /3'),
('126794dd-25ff-47d2-a436-724499733365','893c77db-1d39-4870-8433-434d9ba07b84',2025,7,'Fire',9,8971.86,'new_business',true,'sf_ppr_2026-07-08_manual','Q3 2025 split /3'),
('126794dd-25ff-47d2-a436-724499733365','893c77db-1d39-4870-8433-434d9ba07b84',2025,8,'Fire',9,8971.87,'new_business',true,'sf_ppr_2026-07-08_manual','Q3 2025 split /3'),
('126794dd-25ff-47d2-a436-724499733365','893c77db-1d39-4870-8433-434d9ba07b84',2025,9,'Fire',10,8971.87,'new_business',true,'sf_ppr_2026-07-08_manual','Q3 2025 split /3'),
('126794dd-25ff-47d2-a436-724499733365','893c77db-1d39-4870-8433-434d9ba07b84',2025,7,'Life',1,667.00,'new_business',false,'sf_ppr_2026-07-08_manual','Q3 2025 split /3'),
('126794dd-25ff-47d2-a436-724499733365','893c77db-1d39-4870-8433-434d9ba07b84',2025,8,'Life',1,667.00,'new_business',false,'sf_ppr_2026-07-08_manual','Q3 2025 split /3'),
('126794dd-25ff-47d2-a436-724499733365','893c77db-1d39-4870-8433-434d9ba07b84',2025,9,'Life',1,667.00,'new_business',false,'sf_ppr_2026-07-08_manual','Q3 2025 split /3'),

-- Tommy Q4 2025 (Auto 93/$76,835.75, Fire 39/$39,092.79, Life 3/$3,796.08, Health 1/$311.52)
('126794dd-25ff-47d2-a436-724499733365','893c77db-1d39-4870-8433-434d9ba07b84',2025,10,'Auto',31,25611.91,'new_business',true,'sf_ppr_2026-07-08_manual','Q4 2025 split /3'),
('126794dd-25ff-47d2-a436-724499733365','893c77db-1d39-4870-8433-434d9ba07b84',2025,11,'Auto',31,25611.92,'new_business',true,'sf_ppr_2026-07-08_manual','Q4 2025 split /3'),
('126794dd-25ff-47d2-a436-724499733365','893c77db-1d39-4870-8433-434d9ba07b84',2025,12,'Auto',31,25611.92,'new_business',true,'sf_ppr_2026-07-08_manual','Q4 2025 split /3'),
('126794dd-25ff-47d2-a436-724499733365','893c77db-1d39-4870-8433-434d9ba07b84',2025,10,'Fire',13,13030.93,'new_business',true,'sf_ppr_2026-07-08_manual','Q4 2025 split /3'),
('126794dd-25ff-47d2-a436-724499733365','893c77db-1d39-4870-8433-434d9ba07b84',2025,11,'Fire',13,13030.93,'new_business',true,'sf_ppr_2026-07-08_manual','Q4 2025 split /3'),
('126794dd-25ff-47d2-a436-724499733365','893c77db-1d39-4870-8433-434d9ba07b84',2025,12,'Fire',13,13030.93,'new_business',true,'sf_ppr_2026-07-08_manual','Q4 2025 split /3'),
('126794dd-25ff-47d2-a436-724499733365','893c77db-1d39-4870-8433-434d9ba07b84',2025,10,'Life',1,1265.36,'new_business',false,'sf_ppr_2026-07-08_manual','Q4 2025 split /3'),
('126794dd-25ff-47d2-a436-724499733365','893c77db-1d39-4870-8433-434d9ba07b84',2025,11,'Life',1,1265.36,'new_business',false,'sf_ppr_2026-07-08_manual','Q4 2025 split /3'),
('126794dd-25ff-47d2-a436-724499733365','893c77db-1d39-4870-8433-434d9ba07b84',2025,12,'Life',1,1265.36,'new_business',false,'sf_ppr_2026-07-08_manual','Q4 2025 split /3'),
('126794dd-25ff-47d2-a436-724499733365','893c77db-1d39-4870-8433-434d9ba07b84',2025,12,'Health',1,311.52,'new_business',false,'sf_ppr_2026-07-08_manual','Q4 2025 — single Health PIF placed in Dec'),

-- Tommy Q2 2026 (Auto 100/$77,432.30, Fire 50/$77,703.49, Life 6/$2,774.28)
('126794dd-25ff-47d2-a436-724499733365','893c77db-1d39-4870-8433-434d9ba07b84',2026,4,'Auto',33,25810.77,'new_business',true,'sf_ppr_2026-07-08_manual','Q2 2026 split /3'),
('126794dd-25ff-47d2-a436-724499733365','893c77db-1d39-4870-8433-434d9ba07b84',2026,5,'Auto',33,25810.77,'new_business',true,'sf_ppr_2026-07-08_manual','Q2 2026 split /3'),
('126794dd-25ff-47d2-a436-724499733365','893c77db-1d39-4870-8433-434d9ba07b84',2026,6,'Auto',34,25810.76,'new_business',true,'sf_ppr_2026-07-08_manual','Q2 2026 split /3'),
('126794dd-25ff-47d2-a436-724499733365','893c77db-1d39-4870-8433-434d9ba07b84',2026,4,'Fire',17,25901.16,'new_business',true,'sf_ppr_2026-07-08_manual','Q2 2026 split /3'),
('126794dd-25ff-47d2-a436-724499733365','893c77db-1d39-4870-8433-434d9ba07b84',2026,5,'Fire',17,25901.16,'new_business',true,'sf_ppr_2026-07-08_manual','Q2 2026 split /3'),
('126794dd-25ff-47d2-a436-724499733365','893c77db-1d39-4870-8433-434d9ba07b84',2026,6,'Fire',16,25901.17,'new_business',true,'sf_ppr_2026-07-08_manual','Q2 2026 split /3'),
('126794dd-25ff-47d2-a436-724499733365','893c77db-1d39-4870-8433-434d9ba07b84',2026,4,'Life',2,924.76,'new_business',false,'sf_ppr_2026-07-08_manual','Q2 2026 split /3'),
('126794dd-25ff-47d2-a436-724499733365','893c77db-1d39-4870-8433-434d9ba07b84',2026,5,'Life',2,924.76,'new_business',false,'sf_ppr_2026-07-08_manual','Q2 2026 split /3'),
('126794dd-25ff-47d2-a436-724499733365','893c77db-1d39-4870-8433-434d9ba07b84',2026,6,'Life',2,924.76,'new_business',false,'sf_ppr_2026-07-08_manual','Q2 2026 split /3');

COMMIT;
