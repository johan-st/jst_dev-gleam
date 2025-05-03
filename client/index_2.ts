import { connect, wsconnect, deferred, nuid } from "@nats-io/transport-node";
import { Kvm } from "@nats-io/kv";
import { Objm } from "@nats-io/obj";
import { jetstream, jetstreamManager } from "@nats-io/jetstream";
import { Svcm } from "@nats-io/services";

const nc = await wsconnect({ servers: "demo.nats.io:8443" });
console.log(`connected: ${nc.getServer()}`);

// const jsm = await jetstreamManager(nc);
// let streams = 0;
// for await (const si of jsm.streams.list()) {
//   streams++;
// }
// console.log(`found ${streams} streams`);

// let kvs = 0;
// const kvm = new Kvm(nc);
// for await (const k of kvm.list()) {
//   kvs++;
// }
// console.log(`${kvs} streams are kvs`);

// let objs = 0;
// const objm = new Objm(nc);
// for await (const k of objm.list()) {
//   objs++;
// }
// console.log(`${objs} streams are object stores`);

let services = 0;
const svm = new Svcm(nc);
const c = svm.client();
c.ping().then((r) => {
  console.log(r);
});
for await (const s of await c.ping()) {
  services++;
}
console.log(`${services} services were found`);

await nc.close();