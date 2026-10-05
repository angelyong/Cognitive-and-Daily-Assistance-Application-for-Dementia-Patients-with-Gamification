# MindCare FYP Presentation Script

## Slide 1 — MindCare

Good morning. This project is MindCare, a mobile application that supports dementia patients in their daily routines and helps caregivers monitor their progress. This presentation highlights how the project developed from the initial proposal into the completed system.

## Slide 2 — What Changed

The original proposal contained nine broad functional requirements. During development, the system expanded to thirty-three detailed requirements, including recurring tasks, adaptive cognitive games, analytics, risk indicators and reward games.

## Slide 3 — Problem Statement Evolution

The four original problems involved routine management, low motivation, cognitive overload and fragmented care. A fifth problem was later added because patients also required cognitive activities that matched their dementia type, stage and individual performance.

## Slide 4 — Objectives and Target Users

The final objectives became more specific and measurable. MindCare served both dementia patients and caregivers, while the new adaptive-cognition objective focused on personalised game selection, automatic difficulty adjustment and caregiver supervision.

## Slide 5 — Feature Origins

The features were based on findings from existing applications and previous research. Reminder applications influenced routine support, cognitive applications influenced the games and statistics, while research supported personalisation, accessibility and gamification.

## Slide 6 — Application Comparison

Existing applications provided useful individual features, but none combined all the functions required by MindCare. MindCare integrated reminders, caregiver support, personalised games, adaptive difficulty, risk monitoring and rewards within one application.

## Slide 7 — Prototyping Journey

MindCare applied the Prototyping Model throughout the project. FYP I focused on understanding the problem and designing early prototypes, while feedback guided the core implementation. During FYP II, the system was refined with personalised games, adaptive difficulty, analytics, risk monitoring and rewards before the final product was tested and prepared for presentation.

## Slide 8 — Functional Requirement Expansion

The initial nine requirements were expanded into thirty-three traceable requirements across six modules. This made each function clearer and allowed it to be linked directly to its user role and test cases.

## Slide 9 — New Capabilities

The major additions were complete task recurrence, repeated reminders, personalised cognitive games, adaptive difficulty, detailed caregiver monitoring and a reward pathway. These additions significantly increased the completeness and technical complexity of MindCare.

## Slide 10 — Use-Case Diagram

This use-case diagram presents the functions available to caregivers and dementia patients. It also shows how role-based access separates caregiver management features from patient activities.

## Slide 11 — Architecture and Data Design

The system used Flutter for the mobile interface, Firebase Authentication for user access and Cloud Firestore for application data. Android notification services handled scheduled reminders, while the database connected users, tasks, game sessions, difficulty states and risk records.

## Slide 12 — Role-Based Interface

MindCare provided different interfaces for caregivers and patients while maintaining a consistent design. Caregivers received management and monitoring controls, while patients received simpler task, medication and cognitive-game functions.

## Slide 13 — Core Implementation

Five connected areas formed the main implementation: authentication, recurring task occurrences, reminder processing, adaptive game difficulty and risk evaluation. Firestore updates allowed changes to appear reactively across the relevant screens.

## Slide 14 — Implementation Evidence

The recurrence flow generated task occurrences and reminders from a saved schedule. Game sessions updated adaptive difficulty and change history, while task, cognitive and inactivity data were combined to calculate patient risk levels.

## Slide 15 — Testing Coverage

Testing was performed at multiple levels. The report documented fourteen unit cases, nine integration flows, seventeen system scenarios and thirty-four user acceptance test cases.

## Slide 16 — UAT Results

All nineteen caregiver test cases and fifteen patient test cases passed. This produced a one-hundred-percent pass rate for the thirty-four user acceptance cases.

## Slide 17 — SUS Results

Five participants evaluated MindCare using the System Usability Scale. The average score was ninety-one, which exceeded the project target of eighty-five by six points.

## Slide 18 — Testing Findings

The results showed that users could understand the role-based workflows and complete complex functions such as recurring reminders and adaptive games. However, the usability sample was small, and the risk indicator should remain a caregiver-support tool rather than a clinical diagnosis.

## Slide 19 — Objectives Achieved

All three formal objectives were achieved. MindCare delivered integrated daily support, exceeded its usability target and implemented personalised cognitive games with automatic and caregiver-controlled difficulty adjustment.

## Slide 20 — Future Work

Future improvements could include offline support, iOS compatibility, multilingual and voice features, personalised photos and sounds, locally hosted reward games and larger evaluations involving healthcare professionals.

## Slide 21 — Conclusion

In conclusion, MindCare developed beyond a reminder application into an integrated support platform. It connected daily assistance, adaptive cognitive engagement and caregiver monitoring through one accessible mobile workflow. Thank you.
