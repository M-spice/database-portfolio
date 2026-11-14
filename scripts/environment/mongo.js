const admin = db.getSiblingDB('admin');
admin.auth('root', process.env.MONGO_INITDB_ROOT_PASSWORD);

const build = admin.runCommand({ buildInfo: 1 });
print(`server version: ${build.version} (git ${build.gitVersion})`);
const fcv = admin.runCommand({ getParameter: 1, featureCompatibilityVersion: 1 });
print(`featureCompatibilityVersion: ${fcv.featureCompatibilityVersion.version}`);

const status = rs.status();
print(`replica set: ${status.set}`);
status.members.forEach((m) => print(`  member ${m._id}: ${m.name} ${m.stateStr} health=${m.health}`));
print(`isWritablePrimary: ${db.hello().isWritablePrimary}`);

const server = admin.serverStatus();
print(`storage engine: ${server.storageEngine.name}`);
print(`wiredTiger cache maximum bytes: ${server.wiredTiger.cache['maximum bytes configured']}`);
print('command-line options:');
printjson(admin.runCommand({ getCmdLineOpts: 1 }).parsed);

const scratch = db.getSiblingDB('p1_environment_check');
const session = db.getMongo().startSession();
session.startTransaction({ readConcern: { level: 'snapshot' }, writeConcern: { w: 'majority' } });
session.getDatabase('p1_environment_check').probe.insertOne({ checked_at: new Date() });
session.commitTransaction();
session.endSession();
print(`multi-document transaction committed; documents written: ${scratch.probe.countDocuments({})}`);
scratch.dropDatabase();
