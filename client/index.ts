import { connect, deferred, nuid } from "@nats-io/transport-node";
import { Kvm } from "@nats-io/kv";

// import { connect, deferred, nuid } from "@nats-io/transport-deno";

const nc = await connect({ servers: "demo.nats.io" });
console.log(`connected`);

const subj = nuid.next();

nc.subscribe(subj, {
  callback: (err, msg) => {
    console.log(msg.subject, msg.json());
  },
});


let i = 0;
const d = deferred();
const timer = setInterval(() => {
  i++;
  nc.publish(subj, JSON.stringify({ ts: new Date().toISOString(), i }));
  if (i === 10) {
    clearInterval(timer);
    d.resolve();
  }
}, 1000);

await d;
await nc.drain();