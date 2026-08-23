/// PART 1 (adaptive_difficulty_and_risk_indicator_prompt.md): canonical
/// list of every cognitive game's id/label/set, so StatisticsScreen (and
/// anything else needing "all 13 games" — e.g. a future risk-indicator
/// pass) has one shared source instead of re-deriving it. `id` values
/// match each game file's own `_gameId` constant exactly (see each game's
/// PART 1 doc comment) — these must stay in sync.
class GameCatalogEntry {
  final String id;
  final String label;
  final String gameSet; // 'ad_early' | 'ad_middle' | 'vad_early' | 'vad_middle'

  const GameCatalogEntry({required this.id, required this.label, required this.gameSet});
}

const List<GameCatalogEntry> kGameCatalog = [
  // AD-Early
  GameCatalogEntry(id: 'memory_matching', label: 'Memory Matching', gameSet: 'ad_early'),
  GameCatalogEntry(id: 'category_naming', label: 'Category Naming', gameSet: 'ad_early'),
  GameCatalogEntry(id: 'prospective_memory', label: 'Remember This', gameSet: 'ad_early'),
  GameCatalogEntry(id: 'word_picture_pairing', label: 'Word & Picture', gameSet: 'ad_early'),
  // AD-Middle
  GameCatalogEntry(id: 'picture_recognition', label: 'Picture Match', gameSet: 'ad_middle'),
  GameCatalogEntry(id: 'name_face', label: 'Who Is This?', gameSet: 'ad_middle'),
  GameCatalogEntry(id: 'familiar_sound', label: 'What Made That Sound?', gameSet: 'ad_middle'),
  // VaD-Early
  GameCatalogEntry(id: 'sequencing', label: 'Daily Routine', gameSet: 'vad_early'),
  GameCatalogEntry(id: 'letter_fluency', label: 'Letter Search', gameSet: 'vad_early'),
  GameCatalogEntry(id: 'odd_one_out', label: 'Odd One Out', gameSet: 'vad_early'),
  // VaD-Middle
  GameCatalogEntry(id: 'sorting', label: 'Color/Shape Sorting', gameSet: 'vad_middle'),
  GameCatalogEntry(id: 'guided_daily_steps', label: 'Guided Daily Steps', gameSet: 'vad_middle'),
  GameCatalogEntry(id: 'spot_the_difference', label: 'Spot the Difference', gameSet: 'vad_middle'),
];

String gameLabelFor(String gameId) {
  for (final g in kGameCatalog) {
    if (g.id == gameId) return g.label;
  }
  return gameId;
}
