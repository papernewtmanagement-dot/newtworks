INSERT INTO public.offer_letter_templates
  (agency_id, template_key, title, body_md, version, is_active, notes)
VALUES (
  '126794dd-25ff-47d2-a436-724499733365',
  'standard',
  'Standard offer letter',
$TPL$**{{employer_name}}**
{{agency_address}}

{{offer_date}}

**{{candidate_name}}**

Dear {{candidate_first_name}},

We would like you to join us. This letter sets out the offer in full.

**Position**

You are being offered the position of **{{job_title}}** at {{agency_name}}. Your employer of record is {{employer_name}}. You will report to {{reports_to}}.

**Start date**

Your first day is **{{start_date}}**, unless we agree on a different date in writing.

**Pay**

{{pay_line}}

Pay is issued on the agency's regular payroll schedule, less required withholding. Any commission, bonus or incentive pay is separate from the figure above and is governed by the written plan in force at the time it is earned.

**Licence**

{{license_clause}}

**Your own insurance**

Everyone on this team carries their own insurance and financial services with us. By accepting this offer you agree to move your personal policies to the agency within the first ninety days.

**What this offer depends on**

This offer is contingent on all of the following:

1. Satisfactory reference checks.
2. Satisfactory results from any background check we run.
3. Your proof that you are legally able to work in the United States, provided on or before your first day.

If any of these does not clear, the offer may be withdrawn.

**Employment terms**

Employment with {{employer_name}} is at will. That means either you or the agency may end the employment relationship at any time, with or without cause and with or without notice. Nothing in this letter is a contract of employment for any fixed period, and no one at the agency has authority to promise otherwise unless it is put in writing and signed by the agent.

This letter is the whole of the offer and replaces anything discussed before it.

**Accepting**

Please sign below and return this letter by **{{respond_by}}**.

We are glad to be making this offer, and we are looking forward to having you with us.

Sincerely,

{{agent_name}}
Agent, {{agency_name}}

---

I accept the offer as set out above.

Signature: ______________________________   Date: ______________

Printed name: {{candidate_name}}
$TPL$,
  1,
  true,
  'Fill-in fields are wrapped in double braces and are replaced by the offer form on the candidate page. Reviewed wording covers: position, start date, pay, licence requirement, the personal-insurance commitment signed at offer, contingencies (references now run after the offer), and Texas at-will language.'
)
ON CONFLICT (agency_id, template_key) DO NOTHING;
