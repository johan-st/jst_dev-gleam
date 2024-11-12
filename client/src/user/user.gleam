pub type User {
  Guest
  Authenticated(UserInfo)
}

pub type UserInfo {
  Ad(id: Int, email: String, name: String)
}
