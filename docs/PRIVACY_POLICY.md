# Runewright Privacy Policy

*Effective: [8/3/26]*

## The short version

Runewright collects no data of any kind, personal or otherwise. Runewright has no
account system, no developer server, and no network connection back to its developer.
There is no code path in this app that could transmit your data to me, because I
never built one.

If you somehow find a way to send your personal data to the developer despite the
total absence of any mechanism for doing so, my policy is as follows: I will,
at my sole and capricous discretion, forward it to whichever of the following I judge
most embarrassing — the NSA, Mark Zuckerberg, Congress, your mom, or a
series of low-effort photocopied posters stapled to telephone poles around town.

## The version for Google, regulators, and anyone who wants the literal facts

This section is the actual, factual disclosure. Read it if the joke above raised an
eyebrow — everything here is precise on purpose.

- **No account, no login, no developer server.** Your in-game identity is a
  cryptographic keypair generated on your device and stored only on your device
  (Android encrypted secure storage). Nothing about it is ever sent to the developer.
  If you lose your phone, you lose your key — there is no recovery mechanism, no
  backup server, and nothing the developer can restore for you.
- **No analytics, no crash reporting, no advertising SDKs, no third-party trackers.**
  This app ships with zero third-party data-collection libraries of any kind.
- **Microphone access** ("Sorcerer Mode" voice casting) and **motion sensor access**
  (accelerometer/gyroscope, for gesture casting) are used only if you opt into those
  optional casting modes. Voice enrollment data to help with voice recognition is stored
  locally. Actual usage data for that audio and motion is processed entirely on-device
  in real time and is never recorded to disk, uploaded, or transmitted anywhere. Only
  a resulting match/no-match verdict feeds into local gameplay — the raw audio and
  sensor data are discarded immediately after each check.
- **Local network (Wi-Fi) access** is used to discover and connect directly to a
  nearby opponent's phone for peer-to-peer dueling. During a match, gameplay data
  (moves, cryptographic spell proofs, board state) is exchanged directly between the
  two players' devices over the local network — never through a server, and never to
  the developer. This is the same category of thing as playing a board game across a
  table, just carried over Wi-Fi instead of by hand.
- **No data is sold, rented, or shared with advertisers**, because there is no
  collection pipeline for any such data to enter in the first place.
- **Children's privacy:** Runewright is not directed at children and does not
  knowingly collect data from anyone, of any age, because it does not knowingly
  collect data from anyone.
- **Your rights (GDPR/CCPA/etc.):** access, correction, deletion, and portability
  requests are trivially satisfied, because there is no server-side record of you to
  access, correct, delete, or export.
- **Changes to this policy:** if that ever changes — say, a future online leaderboard
  feature — this document will be updated first, and the change will be described
  here in plain language before it ships.
- **Contact:** [runewrightdev@gmail.com] for questions about this policy.
  And if you use that email address to send me personal data so help me...
