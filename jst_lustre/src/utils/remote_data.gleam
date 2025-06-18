import gleam/list

pub type RemoteData(a, err) {
  NotInitialized
  Pending
  Loaded(a)
  Errored(err)
}

pub fn try_update(
  remote_data: RemoteData(a, err),
  update: fn(a) -> a,
) -> RemoteData(a, err) {
  case remote_data {
    Loaded(a) -> Loaded(update(a))
    _ -> remote_data
  }
}

pub fn map_loaded(
  remote_data data: RemoteData(List(a), err),
  with with: fn(a) -> a,
) -> RemoteData(List(a), err) {
  case data {
    Loaded(list) -> {
      list
      |> list.map(with)
      |> Loaded
    }
    _ -> data
  }
}
