import resolve from "@rollup/plugin-node-resolve";
import commonjs from "@rollup/plugin-commonjs";
import typescript from "@rollup/plugin-typescript";

export default {
  input: "src/plugin.ts",
  output: {
    file: "com.amirdaraee.yc-onion.sdPlugin/bin/plugin.js",
    format: "esm",
    sourcemap: true
  },
  plugins: [resolve({ preferBuiltins: true }), commonjs(), typescript()]
};
