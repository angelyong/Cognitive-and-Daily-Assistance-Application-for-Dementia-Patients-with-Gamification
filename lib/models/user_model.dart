class UserModel {
  String uid;
  String name;
  String email;
  String role;
  int streakPoints;
  int currentStreak;

  UserModel({
    required this.uid,
    required this.name,
    required this.email,
    required this.role,
    required this.streakPoints,
    required this.currentStreak,
  });

  factory UserModel.fromMap(
      Map<String, dynamic> map) {
    return UserModel(
      uid: map['uid'],
      name: map['name'],
      email: map['email'],
      role: map['role'],
      streakPoints: map['streakPoints'],
      currentStreak: map['currentStreak'],
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'uid': uid,
      'name': name,
      'email': email,
      'role': role,
      'streakPoints': streakPoints,
      'currentStreak': currentStreak,
    };
  }
}