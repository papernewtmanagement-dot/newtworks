-- 20260707183124_handbook_peter_cleanup_and_other_reads_table

-- Step 1: re-scrub any Peter/PETER that came back
UPDATE public.handbook
SET content = REPLACE(REPLACE(REPLACE(REPLACE(
                content,
                'PETER''S', 'THE AGENT''S'),
                'PETER',    'THE AGENT'),
                'Peter''s', 'the agent''s'),
                'Peter',    'the agent')
WHERE is_active = true
  AND (content LIKE '%Peter%' OR content LIKE '%PETER%');

-- Step 2: replace Other Reads dropdowns with a 4-column table (Winning & Learning)
UPDATE public.handbook
SET content = REPLACE(
  content,
  E'**Other Reads**\n\n<details><summary>Great Reads</summary>\n\n- Killing Sacred Cows\n- Zero to Six Figures\n- Relentless\n- Missed Fortune 101\n- Built to Last\n- Good to Great\n\n</details>\n\n<details><summary>Good Reads</summary>\n\n- Leadership Strategy and Tactics\n- If You''re Not First, You''re Last\n- Build\n\n</details>\n\n<details><summary>Next on My List</summary>\n\n- Better\n- Smarter Faster Better\n- The Compound Effect\n- The New Psychology of Winning\n- The Four Spiritual Laws of Prosperity\n- Essentialism\n- Selling the Invisible\n- The Invisible Promise\n- Unthinking\n- Selling in a Crisis\n- Virtual Selling\n- Four Thousand Weeks\n- Pitch Anything\n- Supercharged Selling\n\n</details>\n\n<details><summary>Backlog</summary>\n\n- Tax-Free Income for Life\n- E-Myth Mastery\n- The E-Myth Revisited\n- Think and Grow Rich\n- Awakening the Entrepreneur Within\n- Staring Down the Wolf\n- The Way of the Seal\n- Influence\n- Time Management Skills That Work\n- The Six Disciplines of Breakthrough Learning\n- The Bullet Journal Method\n- Rhinoceros Success\n- The Speed of Trust\n- In Search of Excellence\n- SPIN Selling\n- Flip the Script\n- Quiet Leadership\n- Business Secrets from the Bible\n- The Gap and the Gain\n- Checklist Manifesto\n- What You Do Is Who You Are\n- The Go-Giver\n- Flight Plan\n- Hidden Potential\n\n</details>',
  $newtable$<table style="width:100%;border-collapse:collapse;margin:8px 0;">
  <tr>
    <th colspan="4" style="text-align:left;padding:10px 8px;border-bottom:2px solid #ccc;background:#f5f5f5;font-size:16px;">Other Reads</th>
  </tr>
  <tr>
    <th style="text-align:left;padding:8px;border-bottom:2px solid #ccc;background:#f5f5f5;width:25%;">Great Reads</th>
    <th style="text-align:left;padding:8px;border-bottom:2px solid #ccc;background:#f5f5f5;width:25%;">Good Reads</th>
    <th style="text-align:left;padding:8px;border-bottom:2px solid #ccc;background:#f5f5f5;width:25%;">Next on My List</th>
    <th style="text-align:left;padding:8px;border-bottom:2px solid #ccc;background:#f5f5f5;width:25%;">Backlog</th>
  </tr>
  <tr>
    <td style="padding:8px;vertical-align:top;">Killing Sacred Cows<br>Zero to Six Figures<br>Relentless<br>Missed Fortune 101<br>Built to Last<br>Good to Great</td>
    <td style="padding:8px;vertical-align:top;">Leadership Strategy and Tactics<br>If You're Not First, You're Last<br>Build</td>
    <td style="padding:8px;vertical-align:top;">Better<br>Smarter Faster Better<br>The Compound Effect<br>The New Psychology of Winning<br>The Four Spiritual Laws of Prosperity<br>Essentialism<br>Selling the Invisible<br>The Invisible Promise<br>Unthinking<br>Selling in a Crisis<br>Virtual Selling<br>Four Thousand Weeks<br>Pitch Anything<br>Supercharged Selling</td>
    <td style="padding:8px;vertical-align:top;">Tax-Free Income for Life<br>E-Myth Mastery<br>The E-Myth Revisited<br>Think and Grow Rich<br>Awakening the Entrepreneur Within<br>Staring Down the Wolf<br>The Way of the Seal<br>Influence<br>Time Management Skills That Work<br>The Six Disciplines of Breakthrough Learning<br>The Bullet Journal Method<br>Rhinoceros Success<br>The Speed of Trust<br>In Search of Excellence<br>SPIN Selling<br>Flip the Script<br>Quiet Leadership<br>Business Secrets from the Bible<br>The Gap and the Gain<br>Checklist Manifesto<br>What You Do Is Who You Are<br>The Go-Giver<br>Flight Plan<br>Hidden Potential</td>
  </tr>
</table>$newtable$
)
WHERE title = 'Winning & Learning';
