UPDATE hiregauge_rules SET is_active=false, updated_at=NOW()
WHERE rule_name='Moderate everything fresh-hire red flag'
  AND is_active=true;
