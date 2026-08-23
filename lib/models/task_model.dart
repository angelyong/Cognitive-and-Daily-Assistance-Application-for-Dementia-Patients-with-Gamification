class TaskModel {
  String id;
  String patientId;
  String title;
  String description;
  String status;

  TaskModel({
    required this.id,
    required this.patientId,
    required this.title,
    required this.description,
    required this.status,
  });
}