הנה הסקריפט שהרצתי:
```js
const fs = require("fs");
const path = require("path");

const dir = path.join(__dirname, "data");
for (const name of fs.readdirSync(dir)) {
  const text = fs.readFileSync(path.join(dir, name), "utf8");
  console.log(name, text.length);
}
console.log("done");
console.log("finished");
