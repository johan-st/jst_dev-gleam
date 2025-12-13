/// PubSub actor for real-time WebSocket broadcasts.
/// Uses OTP processes to manage topic subscriptions.
import gleam/dict.{type Dict}
import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/otp/actor
import gleam/result

import shared/omni.{type ServerMessage}

pub type Topic {
  Articles
  ShortUrls
  ChatRooms
  ChatMessages(room_id: String)
}

pub type Subscriber =
  Subject(ServerMessage)

pub type Message {
  Subscribe(topic: Topic, subscriber: Subscriber)
  Unsubscribe(topic: Topic, subscriber: Subscriber)
  Broadcast(topic: Topic, message: ServerMessage)
  Shutdown
}

pub opaque type PubSub {
  PubSub(subject: Subject(Message))
}

type State {
  State(subscribers: Dict(String, List(Subscriber)))
}

fn topic_key(topic: Topic) -> String {
  case topic {
    Articles -> "articles"
    ShortUrls -> "short_urls"
    ChatRooms -> "chat_rooms"
    ChatMessages(room_id) -> "chat_messages:" <> room_id
  }
}

/// Start the pubsub actor.
pub fn start() -> Result(PubSub, actor.StartError) {
  actor.new(State(subscribers: dict.new()))
  |> actor.on_message(handle_message)
  |> actor.start
  |> result.map(fn(started) { PubSub(started.data) })
}

fn handle_message(state: State, msg: Message) -> actor.Next(State, Message) {
  case msg {
    Subscribe(topic, subscriber) -> {
      let key = topic_key(topic)
      let current = dict.get(state.subscribers, key) |> result.unwrap([])
      let updated = [subscriber, ..current]
      let new_state =
        State(subscribers: dict.insert(state.subscribers, key, updated))
      actor.continue(new_state)
    }

    Unsubscribe(topic, subscriber) -> {
      let key = topic_key(topic)
      let current = dict.get(state.subscribers, key) |> result.unwrap([])
      let updated = list.filter(current, fn(s) { s != subscriber })
      let new_state =
        State(subscribers: dict.insert(state.subscribers, key, updated))
      actor.continue(new_state)
    }

    Broadcast(topic, message) -> {
      let key = topic_key(topic)
      let subs = dict.get(state.subscribers, key) |> result.unwrap([])
      list.each(subs, fn(sub) { process.send(sub, message) })
      actor.continue(state)
    }

    Shutdown -> actor.stop()
  }
}

/// Subscribe a subject to a topic.
pub fn subscribe(pubsub: PubSub, topic: Topic, subscriber: Subscriber) -> Nil {
  process.send(pubsub.subject, Subscribe(topic, subscriber))
}

/// Unsubscribe a subject from a topic.
pub fn unsubscribe(pubsub: PubSub, topic: Topic, subscriber: Subscriber) -> Nil {
  process.send(pubsub.subject, Unsubscribe(topic, subscriber))
}

/// Broadcast a message to all subscribers of a topic.
pub fn broadcast(pubsub: PubSub, topic: Topic, message: ServerMessage) -> Nil {
  process.send(pubsub.subject, Broadcast(topic, message))
}
