# MindCare

MindCare is a Flutter mobile application designed to support people living with dementia and their caregivers. The application combines daily routine assistance, medication reminders, dementia-friendly cognitive games and caregiver monitoring in one platform.

## Main Features

- Role-based authentication for caregivers and patients
- Patient account creation, editing and unlinking
- Single and recurring task and medication schedules
- Configurable reminder notifications with completed and missed responses
- Patient calendar, task history and occurrence-specific status tracking
- Dementia-type- and stage-specific cognitive games
- Errorless guidance and hints during cognitive activities
- Per-game adaptive difficulty based on recent performance
- Caregiver difficulty overrides and difficulty-change history
- Game statistics, performance trends and patient risk indicators
- Login streaks, points, levels and points-unlocked Just for Fun games
- Adjustable font-size and accessible role-based navigation

## Technology Stack

- Flutter and Dart
- Firebase Authentication
- Cloud Firestore
- Flutter Local Notifications
- Android notification services
- `fl_chart` for performance visualisation
- WebView for external Just for Fun reward games

## Project Structure

```text
lib/
├── models/       Data models and game catalogues
├── screens/      Caregiver, patient and authentication screens
├── services/     Firebase, notification, game and business logic services
├── widgets/      Reusable interface components
└── main.dart     Application entry point and route configuration

assets/           Application assets and sounds
android/          Android project configuration
test/             Flutter test files
```

## Requirements

- Flutter SDK
- Dart SDK included with Flutter
- Android Studio or another Android development environment
- Android emulator or physical Android device
- Firebase project configuration for Authentication and Cloud Firestore

## Setup

1. Clone the repository:

```bash
git clone https://github.com/angelyong/Cognitive-and-Daily-Assistance-Application-for-Dementia-Patients-with-Gamification.git
cd Cognitive-and-Daily-Assistance-Application-for-Dementia-Patients-with-Gamification
```

2. Install dependencies:

```bash
flutter pub get
```

3. Configure the Firebase project for the Android application.

4. Check the project:

```bash
flutter analyze
```

5. Run the application:

```bash
flutter run
```

## Build the Android Application

Debug APK:

```bash
flutter build apk --debug
```

Release APK:

```bash
flutter build apk --release
```

The release APK is generated at:

```text
build/app/outputs/flutter-apk/app-release.apk
```

## Scope

MindCare is a support and assistance tool. It does not diagnose dementia, replace professional medical advice or provide clinical risk assessment.
