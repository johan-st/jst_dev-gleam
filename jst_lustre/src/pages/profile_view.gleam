import components/ui
import lustre/attribute as attr
import lustre/element.{type Element}
import lustre/element/html
import utils/remote_data.{type RemoteData, Errored, Loaded, NotInitialized, Pending}
import gleam/option.{None, Some}
import routes
import utils/user

pub type Callbacks(msg) {
  Callbacks(
    on_username: fn(String) -> msg,
    on_email: fn(String) -> msg,
    on_old_password: fn(String) -> msg,
    on_new_password: fn(String) -> msg,
    on_confirm_password: fn(String) -> msg,
    on_save: msg,
    on_change_password: msg,
    on_retry: msg,
  )
}

pub fn view(
  profile_user: RemoteData(user.UserFull, a),
  profile_form_username: String,
  profile_form_email: String,
  profile_form_new_password: String,
  profile_form_confirm_password: String,
  profile_form_old_password: String,
  profile_saving: Bool,
  password_saving: Bool,
  cbs: Callbacks(msg),
) -> List(Element(msg)) {
  let header =
    ui.page_header(
      "Your Profile",
      Some("Update your personal information and change password"),
    )
  let content = case profile_user {
    NotInitialized -> [ui.loading_state("Loading profile", None, ui.ColorTeal)]
    Pending(Some(_user), _) -> [ui.loading_state("Loading profile (could have been optimistic)", None, ui.ColorTeal)]
    Pending(None, _) -> [ui.loading_state("Loading profile...", None, ui.ColorTeal)]
    Errored(_, _) -> [ui.error_state(ui.ErrorGeneric, "Failed to load profile", "Please try again", Some(cbs.on_retry))]
    Loaded(_user_full, _, _) -> [
      ui.card("profile", [
        html.h3([attr.class("text-lg text-pink-700 font-light mb-4")], [html.text("Profile Information")]),
        html.div([attr.class("space-y-4 max-w-xl")], [
          ui.form_input("Username", profile_form_username, "Your username", "text", True, None, cbs.on_username),
          ui.form_input("Email", profile_form_email, "you@example.com", "email", True, None, cbs.on_email),
          html.div([attr.class("flex gap-3")], [
            ui.button(
              case profile_saving { True -> "Saving..." False -> "Save Changes" },
              ui.ColorTeal,
              case profile_saving { True -> ui.ButtonStatePending False -> ui.ButtonStateNormal },
              cbs.on_save,
            ),
          ]),
        ]),
      ]),
      ui.card("password", [
        html.h3([attr.class("text-lg text-pink-700 font-light mb-4")], [html.text("Change Password")]),
        html.div([attr.class("space-y-4 max-w-xl")], [
          ui.form_input("Current Password", profile_form_old_password, "Current password", "password", True, None, cbs.on_old_password),
          ui.form_input("New Password", profile_form_new_password, "New password", "password", False, None, cbs.on_new_password),
          ui.form_input(
            "Confirm Password",
            profile_form_confirm_password,
            "Confirm new password",
            "password",
            False,
            case profile_form_new_password, profile_form_confirm_password {
              "", _ -> None
              _, "" -> None
              new_pw, confirm_pw -> case new_pw == confirm_pw { True -> None False -> Some("Passwords do not match") }
            },
            cbs.on_confirm_password,
          ),
          html.div([attr.class("text-sm text-zinc-400")], [html.text("Leave blank to keep your current password.")]),
          html.div([attr.class("flex gap-3")], [
            ui.button(
              case password_saving { True -> "Changing..." False -> "Change Password" },
              ui.ColorTeal,
              case password_saving {
                True -> ui.ButtonStatePending
                False -> {
                  let invalid =
                    profile_form_old_password == ""
                    || profile_form_new_password == ""
                    || profile_form_confirm_password == ""
                    || profile_form_new_password != profile_form_confirm_password
                  case invalid { True -> ui.ButtonStateDisabled False -> ui.ButtonStateNormal }
                }
              },
              cbs.on_change_password,
            ),
          ]),
        ]),
      ]),
    ]
  }
  [header, ..content]
}

