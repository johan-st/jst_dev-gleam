import { connect, wsconnect, deferred, nuid } from "@nats-io/transport-node";

// const nc = await connect({ servers: "demo.nats.io" });
const nc = await wsconnect({ servers: "demo.nats.io:8443" });

console.log(`connected`);

const subj = nuid.next();

nc.subscribe(subj, {
  callback: (err, msg) => {
    if (err) {
      console.error(err);
    }
    console.log(msg.subject, msg.json());
  },
});

let i = 0;
const d = deferred();
const timer = setInterval(() => {
  i++;
  nc.publish(subj, JSON.stringify({ ts: new Date().toISOString(), i }));
  if (i === 1000) {
    clearInterval(timer);
    d.resolve();
  }
}, 0);

await d;
await nc.drain();