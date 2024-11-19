pub type User {
  Authenticated(UserInfo)
}

pub type UserInfo {
  Ad(id: Int, email: String, name: String)
}
