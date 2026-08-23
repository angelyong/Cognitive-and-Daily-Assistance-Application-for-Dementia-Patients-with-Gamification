import 'package:flutter/material.dart';

import 'package:testproject/theme/app_colors.dart';

/// A patient's dementia stage, captured by the caregiver at account
/// creation (AddPatientScreen) and shown as a badge wherever patients are
/// listed.
///
/// Deliberate simplification: clinical staging models often use 3+ stages
/// (e.g. mild/moderate/severe). This implements exactly the 2-stage model
/// requested (Early / Middle) — not an oversight; a "Late stage" option
/// could be added later if wanted.
enum DementiaStage { early, middle }

extension DementiaStageX on DementiaStage {
  static const String firestoreField = 'dementiaStage';

  static DementiaStage fromFirestore(String? value) {
    switch (value) {
      case 'middle':
        return DementiaStage.middle;
      case 'early':
      default:
        return DementiaStage.early;
    }
  }

  String get firestoreValue {
    switch (this) {
      case DementiaStage.early:
        return 'early';
      case DementiaStage.middle:
        return 'middle';
    }
  }

  String get label {
    switch (this) {
      case DementiaStage.early:
        return 'Early Stage';
      case DementiaStage.middle:
        return 'Middle Stage';
    }
  }

  Color get color {
    switch (this) {
      case DementiaStage.early:
        return AppColors.stageEarly;
      case DementiaStage.middle:
        return AppColors.stageMiddle;
    }
  }

  /// How many of the 2 progression dots are filled — 1 for Early, 2 for
  /// Middle, reading as "how far along" at a glance.
  int get filledDots {
    switch (this) {
      case DementiaStage.early:
        return 1;
      case DementiaStage.middle:
        return 2;
    }
  }
}

/// A patient's dementia type/diagnosis, captured alongside stage.
///
/// Icons below are chosen for quick, distinct visual identification when
/// scanning a patient list — NOT clinical symbolism for each condition.
///
/// Deliberately only 2 of the 4 clinically common types — Lewy Body and
/// Frontotemporal (FTD) are intentionally excluded, not an oversight.
/// [fromFirestore] still maps their old Firestore values ('lewy_body',
/// 'ftd') to the default rather than crashing, so any patient doc created
/// before this change still loads instead of throwing.
enum DementiaType { alzheimers, vascular }

extension DementiaTypeX on DementiaType {
  static const String firestoreField = 'dementiaType';

  static DementiaType fromFirestore(String? value) {
    switch (value) {
      case 'vascular':
        return DementiaType.vascular;
      case 'alzheimers':
      default:
        // Also the fallback for the now-removed 'lewy_body'/'ftd' values,
        // so an old patient doc with either still loads rather than
        // throwing — see class doc comment.
        return DementiaType.alzheimers;
    }
  }

  String get firestoreValue {
    switch (this) {
      case DementiaType.alzheimers:
        return 'alzheimers';
      case DementiaType.vascular:
        return 'vascular';
    }
  }

  String get label {
    switch (this) {
      case DementiaType.alzheimers:
        return "Alzheimer's";
      case DementiaType.vascular:
        return 'Vascular Dementia';
    }
  }

  IconData get icon {
    switch (this) {
      case DementiaType.alzheimers:
        return Icons.psychology;
      case DementiaType.vascular:
        return Icons.bloodtype;
    }
  }

  Color get color {
    switch (this) {
      case DementiaType.alzheimers:
        return AppColors.typeAlzheimers;
      case DementiaType.vascular:
        return AppColors.typeVascular;
    }
  }
}
