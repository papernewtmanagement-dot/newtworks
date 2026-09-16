import { T } from "../lib/theme.js";

// ─── CTS Sales Profile Reference ─────────────────────────────
// Peter's own take of the CTS Sales Profile, captured 2026-07-19,
// preserved here as a reference for what the third-party CTS instrument
// asks candidates. The CTS is sent as the second-step assessment after
// the Newtworks assessment (see hiring-pipeline: cts_sales_profile_register_url).
// Peter's responses are shown so this doubles as an example completed
// profile.

const step1 = [
  {
    prompt: "Which is mostly TRUE?",
    choices: [
      { text: "The CTS rewards you for selling yourself (describing yourself in unrealistic favorable ways).", picked: false },
      { text: "When individuals take personality tests, they usually describe themselves negatively.", picked: true },
      { text: "It is to your benefit to be accurate and sometimes self-critical when responding to the CTS.", picked: false },
      { text: "When taking the CTS, it is better to describe yourself in a very positive way so that you seem like an ideal candidate or employee.", picked: false },
    ],
  },
  {
    prompt: "Which is mostly FALSE?",
    choices: [
      { text: "The CTS has been designed to identify when you describe yourself like an ideal candidate or employee.", picked: true },
      { text: "When individuals take personality tests, they will often describe themselves in a very favorable way.", picked: false },
      { text: "It is to your benefit to describe yourself in an accurate, but sometimes self-critical way.", picked: false },
      { text: "When taking the CTS, it is to your benefit to exaggerate your strengths and downplay your weaknesses.", picked: false },
    ],
  },
];

// [word, familiarity 0-6, nonsense?]
const step2 = [
  ["Manic", 6, false],
  ["Flux", 4, false],
  ["Pristine", 5, false],
  ["Stanch", 1, false],
  ["Photon", 4, false],
  ["Nebulous", 4, false],
  ["Litigious", 4, false],
  ["Sopheal", 0, true],
  ["Successor", 6, false],
  ["Sophicious", 2, true],
  ["Respart", 2, true],
  ["Philastotle", 0, true],
  ["Synergy", 5, false],
  ["Jargon", 4, false],
  ["Blosterize", 2, true],
  ["Cranium", 5, false],
  ["Correlation", 6, false],
  ["Entropy", 4, false],
  ["Talt", 2, true],
  ["Mugwump", 1, false],
  ["Zither", 3, false],
  ["Onospectic", 0, true],
  ["Denstile", 3, true],
  ["Woodbine", 3, false],
  ["Predontic", 4, true],
  ["Delectable", 6, false],
  ["Thespian", 2, false],
  ["Febrile", 4, false],
];

const step3 = [
  { q: "Wade bicycles at 10 mph and arrives at his office in 15 minutes. What is the distance in miles?", choices: ["1.5", "2.5", "5", "4", "3.5"], picked: 1 },
  { q: "Carol's alarm is set to 7:30 but she wakes up 45 minutes early and turns it off. What time did she wake up?", choices: ["6:55", "6:45", "5:45", "6:50", "7:00"], picked: 3 },
  { q: "What is the second letter in the 3-letter word that means \"regular employment\"?", choices: ["a", "e", "i", "o", "u"], picked: 4 },
  { q: "Cara plants 5 seeds in 2 minutes. Wade plants 3 times as many seeds in half the time. Together in 10 minutes?", choices: ["100", "150", "175", "200", "300"], picked: 3 },
  { q: "FISH is to OCEAN as BIRD is to:", choices: ["NEXT", "TREE", "SKY", "GROUND", "CAGE"], picked: 3 },
  { q: "Katie's orange tree has 30 oranges — three times as many fruits as Lisa's tree BEFORE Lisa harvested half her limes. How many limes does Lisa have now?", choices: ["10", "45", "90", "15", "5"], picked: 2 },
  { q: "A scuba diver is 33 ft below sea level; a hiker is 64 ft above sea level directly overhead. How many feet apart?", choices: ["31", "97", "60", "100", "33"], picked: 3 },
  { q: "Which pair of words has the SAME meaning?", choices: ["illusion : mirage", "intense : apathetic", "bewildered : lucid", "impish : solemn", "captivating : loathsome"], picked: 1 },
  { q: "Libby sold $60 of vegetables. Jess sold ¾ of what Libby sold. Stephanie sold ⅓ of what Jess sold. How much did they all sell together?", choices: ["$125", "$120", "$100", "$95", "$80"], picked: 4 },
  { q: "FLAG is to COUNTRY as RING is to:", choices: ["KISS", "ACCIDENT", "HATE", "MARRIAGE", "CONTRACT"], picked: 3 },
  { q: "A ship sails at 15 mph and motors at 5 mph. It sails 6 hours out to its destination, then motors home. How long is the return trip?", choices: ["2 hours", "8 hours", "15 hours", "18 hours", "20 hours"], picked: 1 },
  { q: "Twenty percent of what number equals five percent of 680?", choices: ["136", "170", "64", "420", "1360"], picked: 0 },
  { q: "Brett has 2 dogs. Meaghan has four times as many cats as Brett has dogs. If Brett adopts two more dogs, how many cats must Meaghan adopt to maintain the ratio?", choices: ["8", "4", "2", "6", "10"], picked: 2 },
  { q: "Which vowel appears most often in this sentence you are reading?", choices: ["s", "o", "n", "i", "e"], picked: 1 },
  { q: "Mike caught 22 fish this week — 3⅔ times as many as last week. How many fish did he catch last week?", choices: ["8", "10", "6", "4", "5"], picked: 1 },
  { q: "Rearrange \"the to dog the walk park\" into a proper statement. What is the last letter of the third word?", choices: ["k", "e", "g", "r", "t"], picked: 1 },
  { q: "What number is missing in the series: 243 — 81 — 27 — ___ — 3 — 1?", choices: ["6", "9", "5", "7", "12"], picked: 2 },
  { q: "Mark has 64 paintings. Day one he sells ¼. Each day after he sells half of what he started the day with. How many are left after four days?", choices: ["32", "10", "8", "6", "3"], picked: 0 },
  { q: "Which pair of words has the OPPOSITE meaning?", choices: ["similar : alike", "scorn : disdain", "elated : miserable", "facade : pretense", "ecstatic : exultant"], picked: 1 },
  { q: "Jason swam 3½ miles then another 3¼. Rachel swam 2⅔ then another 4½. How many more miles did Rachel swim?", choices: ["1/12", "1/2", "3/12", "3/4", "5/12"], picked: 4 },
  { q: "Three diagonals are drawn inside a hexagon, each passing through the center. How many triangles are formed?", choices: ["0", "1", "3", "6", "8"], picked: 4 },
  { q: "What number is missing in the series: 4 — 5 — 7 — 10 — 14 — 19 — ___?", choices: ["25", "23", "21", "27", "22"], picked: 0 },
  { q: "______ is to MIGRATION as FAITH is to PILGRIMAGE.", choices: ["ANIMAL", "SIGN", "LONG", "INSTINCT", "BIRD"], picked: 0 },
  { q: "If 9 pints of ice cream cost $54, how much do 2 pints cost?", choices: ["$6", "$14", "$10", "$12", "$15"], picked: 1 },
  { q: "What is the sixth letter in the 8-letter word starting with \"c\" meaning \"to preserve or protect a resource\"?", choices: ["r", "n", "e", "v", "c"], picked: 4 },
  { q: "Given: \"All scientists have completed graduate school. Marilyn completed graduate school.\" How would you characterize \"Marilyn is a scientist\"?", choices: ["It is a true statement.", "It is a false statement.", "It is uncertain whether the statement is true or false."], picked: 0 },
  { q: "How many times does 9 directly precede 2 in this sequence: 12909296292629?", choices: ["2", "4", "5", "0", "1"], picked: 4 },
  { q: "Which pair are ANTONYMS?", choices: ["egotistical : narcissistic", "ardor : zeal", "seditious : provocative", "abhorrent : egregious", "prodigious : diminutive"], picked: 0 },
  { q: "Evelyn had 9 dolls, but lost ⅓ at daycare. How many total would she have if she hadn't lost them?", choices: ["12", "9", "27", "3", "6"], picked: 2 },
  { q: "LUGGAGE is to CLOTHING as CAR is to:", choices: ["TRAVEL", "PEOPLE", "ROAD", "AIRPLANE", "TRUNK"], picked: 1 },
  { q: "If a line is drawn vertically through the middle of a rectangle, how many right angles appear in the picture?", choices: ["0", "4", "8", "2", "16"], picked: 4 },
  { q: "Rearrange \"Eggs all don't basket your put one in\" into a proper statement. What is the first vowel in the last word?", choices: ["e", "b", "o", "a", "d"], picked: 1 },
  { q: "A storage closet holds 12 boxes stacked, each 10 inches high. How many feet are there between the top of the third box and the bottom of the tenth box?", choices: ["2.5", "70", "20", "10", "5"], picked: 1 },
  { q: "Which pair are SYNONYMS?", choices: ["clement : magnanimous", "duplicity : rectitude", "quixotic : pragmatic", "cogitate : disregard", "facetious : pensive"], picked: 0 },
  { q: "A chicken coop holds 10 hens OR 20 chicks. If ⅖ of the hens in a full coop are removed, how many new chicks could fit?", choices: ["2", "4", "8", "10", "12"], picked: 4 },
];

// picked: 1-6 (Disagree Strongly … Agree Strongly)
const step4 = [
  ["The majority of people care only about themselves (and not about others or their well-being).", 5],
  ["I believe it is difficult for most people to be self-sufficient and productive unless they get the right breaks.", 2],
  ["I seldom, if ever, lack the confidence to tell others how I feel, even my boss or supervisor.", 6],
  ["I can get easily bored if a project requires too much analysis or precise attention to detail.", 2],
  ["I thoroughly enjoy working in groups where the leadership and decision making are shared.", 1],
  ["I have never been dishonest in my communications with others.", 5],
  ["Most employees are motivated more by their paycheck than the quality of their work.", 4],
  ["I would rather work on my own (than work in a team where leadership is shared).", 6],
  ["Fame and fortune are more important to me (than personal satisfaction of a job well done).", 3],
  ["I typically prioritize my work and seldom spend my time on charitable causes.", 2],
  ["Even in challenging or demanding situations, almost everyone is honest and trustworthy.", 6],
  ["I am usually so intense and impatient that I find it difficult to slow down and pace myself.", 4],
  ["I nearly always enjoy job duties that involve researching and organizing complex information.", 5],
  ["Achieving our goals in life has more to do with seizing opportunities and very little to do with luck.", 3],
  ["The great majority of people are worthy of our trust, even when no one is watching them.", 2],
  ["I have sometimes gossiped about others (even though I may not have known all the facts).", 1],
  ["When completing projects, I am usually more easy-going (than intense and impatient).", 5],
  ["I seldom, if ever, have a problem asserting myself at work, even when I am around aggressive or authoritative people.", 6],
  ["I believe most people's lives are guided by random events, not the choices we make.", 2],
  ["I would really enjoy the attention and recognition that comes from being famous.", 3],
  ["There are times when I find it difficult to express my compassion and caring concern for others.", 5],
  ["Others would say I am usually more agreeable and accommodating (than independent and controlling).", 1],
  ["I nearly always enjoy job duties that require deep concentration and attention to detail.", 6],
  ["There have been times I have covered up my faults or failures and not been completely honest with others.", 2],
  ["I am patient and methodical when completing projects and can easily tolerate routine or repetitive job duties, even if they seem to have no purpose.", 4],
  ["I honestly have no desire to receive the attention that comes from wearing designer clothes or driving fancy cars.", 3],
  ["If I know it might offend others who work with me, I avoid asserting myself or my beliefs.", 5],
  ["Others who know me would say I am more formal and reserved (than warm and caring).", 2],
  ["When making decisions I usually rely more on my intuition and experience and avoid getting bogged down in the detail.", 6],
  ["Security and predictability are more important to me (than independence and control).", 3],
  ["Sometimes I am envious of others.", 5],
  ["When it comes to completing projects, I am quite patient and tolerant if I am interrupted or delayed.", 2],
  ["At work, I don't have a problem saying \"no\" when I am asked to do job duties that are not my responsibility.", 4],
  ["I believe most people don't achieve their goals because of circumstances beyond their control.", 2],
  ["I would rather have just a few close friends (than have thousands of people know my name).", 6],
  ["Those who know me would say I am so often focused on my work that I have little time to spend helping others with their personal problems.", 1],
  ["When making decisions, I usually rely more on my knowledge and experience (than detailed analysis).", 3],
  ["Most people will sometimes lie, cheat, or steal if they know they won't get caught.", 4],
  ["Whether at work or in social situations, I sometimes find it difficult to assert myself and take control of the conversation.", 2],
  ["If I promise someone I am going to do something, I always follow through.", 5],
  ["I am usually more motivated by my need for independence and control (than a need to please others).", 1],
  ["For a job well done, I would rather be thanked privately without any ceremony.", 6],
  ["I am so results-oriented that I sometimes lack the patience to follow step-by-step procedures.", 3],
  ["I believe the great majority of people who fail to achieve their goals have not taken advantage of their opportunities.", 2],
  ["When interacting with non-family, I am usually more private and controlled (than open and expressive).", 4],
  ["I must admit that I work best on my own without direct supervision.", 6],
  ["If I had a choice, I would rather delegate research and analysis to someone else (than do it myself).", 3],
  ["I would really enjoy a lifestyle where I regularly entertained rich and well-known people.", 2],
  ["Once I get started on a project, I am so intensely driven to complete it that I find it difficult to take a break.", 5],
  ["Others who know me well would describe me as kindhearted and ready to help whenever asked.", 3],
  ["Nearly all the bad things that happen to people result in something positive.", 6],
  ["Whether it is a client, a customer, or a fellow employee, I sometimes feel nervous or anxious when I must assert myself to take control.", 2],
  ["When there is a bank error in favor of the customer, most customers will report it to the bank.", 5],
  ["There are times when I find it difficult to admit my mistakes even though I know I am wrong.", 3],
  ["The people who really know me would say I am usually impatient and intensely driven to reach my goals.", 6],
  ["When I am working with others, I find it easy to give up control and allow others to make the decisions.", 2],
  ["I believe the decisions we make (and not luck or happenstance) ultimately determine our success or failure.", 3],
  ["When making decisions, I mostly rely on using analysis and research (more than my judgment/feelings).", 5],
  ["Even when I am working, I am more warm, expressive, and caring (than private and reserved).", 1],
  ["When at work, if a fellow employee asks me to do something I don't want to do, there are times when I find it difficult to assert myself and say, \"no.\"", 3],
  ["There are times when I have intentionally listened to someone else's private conversations.", 2],
  ["I have no desire to be so famous that everyone recognizes me wherever I go.", 6],
  ["If employees know they won't get caught, there are times when they will take advantage of their employer.", 2],
  ["I thoroughly enjoy working in groups where the leadership and decision making are shared.", 4],
  ["I can get easily bored if a project requires too much analysis or precise attention to detail.", 2],
  ["I believe it is difficult for most people to be self-sufficient and productive unless they get the right breaks.", 5],
  ["Fame and fortune are more important to me (than personal satisfaction of a job well done).", 1],
  ["I seldom, if ever, lack the confidence to tell others how I feel, even my boss or supervisor.", 5],
  ["The majority of people care only about themselves (and not about others or their well-being).", 6],
  ["I have never been dishonest in my communications with others.", 2],
  ["I am usually so intense and impatient that I find it difficult to slow down and pace myself.", 5],
  ["I typically prioritize my work and seldom spend my time on charitable causes.", 4],
];

const LIKERT = [
  "Disagree Strongly",
  "Disagree",
  "Disagree Slightly",
  "Agree Slightly",
  "Agree",
  "Agree Strongly",
];

const Section = ({ n, title, children }) => (
  <div style={{ marginBottom: 28 }}>
    <div style={{ fontSize: 13, fontWeight: 700, color: T.slate900, letterSpacing: "-0.01em", marginBottom: 10, paddingBottom: 6, borderBottom: `1px solid ${T.slate200}` }}>
      Step {n} — {title}
    </div>
    {children}
  </div>
);

const Radio = ({ picked }) => (
  <span style={{ display: "inline-block", width: 12, height: 12, borderRadius: "50%", border: `1.5px solid ${picked ? T.slate900 : T.slate300}`, background: picked ? T.slate900 : "transparent", flexShrink: 0, marginTop: 3 }} />
);

export default function TeamCTSReference() {
  return (
    <div style={{ maxWidth: 900 }}>
      <div style={{ background: T.slate50, border: `1px solid ${T.slate200}`, borderRadius: 10, padding: 14, marginBottom: 20 }}>
        <div style={{ fontSize: 12, color: T.slate700, lineHeight: 1.55 }}>
          Reference copy of the <strong>CTS Sales Profile</strong> — the second-step assessment sent to candidates after they finish the Newtworks assessment. Captured 2026-07-19 with Peter's own responses shown, so it doubles as an example completed profile. Answers marked ●. CTS registration link lives in <code>settings.cts_sales_profile_register_url</code>.
        </div>
      </div>

      {/* Step 1 */}
      <Section n={1} title="Instructions Comprehension Check">
        {step1.map((item, i) => (
          <div key={i} style={{ marginBottom: 14 }}>
            <div style={{ fontSize: 12, fontWeight: 600, color: T.slate900, marginBottom: 6 }}>{item.prompt}</div>
            {item.choices.map((c, j) => (
              <div key={j} style={{ display: "flex", gap: 8, alignItems: "flex-start", padding: "4px 0", fontSize: 12, color: c.picked ? T.slate900 : T.slate600 }}>
                <Radio picked={c.picked} />
                <div>{c.text}</div>
              </div>
            ))}
          </div>
        ))}
      </Section>

      {/* Step 2 */}
      <Section n={2} title="Vocabulary Comprehension Test (VCT)">
        <div style={{ fontSize: 11, color: T.slate500, marginBottom: 10 }}>0 = do not know · 6 = know well · Peter's rating shown · <span style={{ color: T.amber700 || "#b45309" }}>italic</span> = nonsense word (correct answer is 0)</div>
        <div style={{ display: "grid", gridTemplateColumns: "repeat(auto-fill, minmax(180px, 1fr))", gap: "6px 16px" }}>
          {step2.map(([word, rating, nonsense], i) => (
            <div key={i} style={{ display: "flex", justifyContent: "space-between", fontSize: 12, padding: "3px 0", borderBottom: `1px dotted ${T.slate200}` }}>
              <span style={{ color: T.slate800, fontStyle: nonsense ? "italic" : "normal" }}>{word}{nonsense ? " *" : ""}</span>
              <span style={{ fontWeight: 600, color: nonsense && rating > 0 ? "#b45309" : T.slate900 }}>{rating}</span>
            </div>
          ))}
        </div>
      </Section>

      {/* Step 3 */}
      <Section n={3} title="Math / Verbal / Reasoning">
        {step3.map((item, i) => (
          <div key={i} style={{ marginBottom: 14, paddingBottom: 10, borderBottom: `1px dotted ${T.slate200}` }}>
            <div style={{ fontSize: 12, fontWeight: 600, color: T.slate900, marginBottom: 6 }}>Q{i + 1}. {item.q}</div>
            <div style={{ display: "flex", flexWrap: "wrap", gap: "4px 18px" }}>
              {item.choices.map((c, j) => (
                <div key={j} style={{ display: "flex", gap: 6, alignItems: "flex-start", fontSize: 12, color: j === item.picked ? T.slate900 : T.slate600, fontWeight: j === item.picked ? 600 : 400 }}>
                  <Radio picked={j === item.picked} />
                  <div>{c}</div>
                </div>
              ))}
            </div>
          </div>
        ))}
      </Section>

      {/* Step 4 */}
      <Section n={4} title="CTS Personality Items (6-point Likert)">
        <div style={{ fontSize: 11, color: T.slate500, marginBottom: 10 }}>Scale: 1 Disagree Strongly · 2 Disagree · 3 Disagree Slightly · 4 Agree Slightly · 5 Agree · 6 Agree Strongly. Peter's rating shown at right.</div>
        {step4.map(([text, picked], i) => (
          <div key={i} style={{ display: "flex", justifyContent: "space-between", gap: 12, padding: "6px 0", borderBottom: `1px dotted ${T.slate200}`, fontSize: 12 }}>
            <div style={{ color: T.slate800, flex: 1 }}><span style={{ color: T.slate500, marginRight: 6 }}>Q{i + 1}.</span>{text}</div>
            <div style={{ flexShrink: 0, textAlign: "right", minWidth: 140 }}>
              <span style={{ fontWeight: 700, color: T.slate900 }}>{picked}</span>
              <span style={{ color: T.slate500, marginLeft: 6 }}>{LIKERT[picked - 1]}</span>
            </div>
          </div>
        ))}
      </Section>
    </div>
  );
}
