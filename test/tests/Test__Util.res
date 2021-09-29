open Belt
module Assert = BsMocha.Assert

open Js.Promise

exception Exn(string)

// wrapper around BsMocha's Assertions
let runner: (unit => unit) => Promise.promise<result<unit, exn>> = %raw(` function(f) {
    var tmp
    try {
      f()
      tmp = {
        TAG: 0,
        _0: undefined,
        [Symbol.for("name")]: "Ok"
      };
    }
    catch (raw_exn){
      tmp = 
        {
          TAG: 1,
          _0: raw_exn,
          [Symbol.for("name")]: "Error"
        };
    }
    return $$Promise.resolved(tmp);
  }`)

module Path = {
  let toAbsolute = filepath => {
    let dirname: option<string> = %bs.node(__dirname)
    switch dirname {
    | None => Node.Process.cwd()
    | Some(dirname) => Node.Path.resolve(dirname, filepath)
    }
  }

  // replacement of ExtensionContext.getExtensionPath as ExtensionContext.t is out of reach
  let extensionPath = () => {
    let dirname: option<string> = %bs.node(__dirname)
    switch dirname {
    | None => Node.Process.cwd()
    | Some(dirname) => Node.Path.resolve(dirname, "../../../../")
    }
  }

  // replacement of ExtensionContext.globalStoragePath as ExtensionContext.t is out ofreach
  let globalStoragePath = () => {
    let dirname: option<string> = %bs.node(__dirname)
    switch dirname {
    | None => Node.Process.cwd()
    | Some(dirname) =>
      // this directory should be ignored by git
      Node.Path.resolve(dirname, "../../../../test/globalStoragePath")
    }
  }

  let asset = filepath => Node.Path.join([extensionPath(), "test/tests/assets", filepath])
}

// to prevent an extension from being activated twice
let activationSingleton = ref(None)

let activateExtension = (): State__Type.channels => {
  switch activationSingleton.contents {
  | None =>
    // activate the extension
    let disposables = []
    let extensionPath = Path.extensionPath()
    let globalStoragePath = Path.globalStoragePath()
    let channels = Main.activateWithoutContext(disposables, extensionPath, globalStoragePath)
    // store the singleton of activation
    activationSingleton := Some(channels)
    channels
  | Some(channels) => channels
  }
}

let openFile = (fileName): Promise.t<VSCode.TextEditor.t> =>
  VSCode.Window.showTextDocumentWithUri(VSCode.Uri.file(fileName), None)

let activateExtensionAndOpenFile = fileName => {
  let channels = activateExtension()
  openFile(fileName)->Promise.map(editor => (editor, channels))
}

@module("vscode") @scope("commands")
external executeCommand: string => Promise.t<option<State.t>> = "executeCommand"

let wait = ms => {
  let (promise, resolve) = Promise.pending()
  Js.Global.setTimeout(resolve, ms)->ignore
  promise
}

module Q = {
  let toPromise = f =>
    Js.Promise.make((~resolve, ~reject) =>
      f->Promise.get(x =>
        switch x {
        | Error(error) => reject(. error)
        | Ok(result) => resolve(. result)
        }
      )
    )

  let it = (s, f: unit => Promise.t<result<'a, 'error>>) =>
    BsMocha.Promise.it(s, () => f()->toPromise)

  let it_only = (s, f) => BsMocha.Promise.it_only(s, () => f()->toPromise)

  let it_skip = (s, f) => BsMocha.Promise.it_skip(s, () => f()->toPromise)

  let before = f => BsMocha.Promise.before(() => f()->toPromise)
  let before_each = f => BsMocha.Promise.before_each(() => f()->toPromise)
  let after = f => BsMocha.Promise.after(() => f()->toPromise)
  let after_each = f => BsMocha.Promise.after_each(() => f()->toPromise)
}

module A = {
  let equal = (expected, actual) => runner(() => BsMocha.Assert.equal(actual, expected))
  let deep_equal = (expected, actual) => runner(() => BsMocha.Assert.deep_equal(actual, expected))
  let deep_strict_equal = (expected, actual) =>
    runner(() => BsMocha.Assert.deep_strict_equal(actual, expected))
  let fail = value => runner(() => BsMocha.Assert.fail(value))
}

module Strings = {
  // trim and replace all occurences of line breaks with "\n"
  let normalize = string => {
    open Js.String
    replaceByRe(%re("/\\r\\n|\\r/g"), "\n", trim(string))
  }

  let serialize = xs => Js.Array.joinWith("\n", xs)

  let serializeWith = (f, xs) => xs->Array.map(f)->serialize

  let breakInput = (input: string, breakpoints: array<int>) => {
    let breakpoints' = Array.concat([0], breakpoints)

    breakpoints'
    ->Array.mapWithIndex((i, x: int) =>
      switch breakpoints'[i + 1] {
      | Some(next) => (x, next - x)
      | None => (x, Js.String.length(input) - x)
      }
    )
    ->Array.map(((from, length)) => Js.String.substrAtMost(~from, ~length, input))
  }
}

module Golden = {
  // bindings for jsdiff
  module Diff = {
    type t =
      | Added(string)
      | Removed(string)
      | NoChange(string)

    let getValue = x =>
      switch x {
      | Added(string) => string
      | Removed(string) => string
      | NoChange(string) => string
      }

    type changeObject = {"value": string, "added": bool, "removed": bool}

    // [@bs.module "diff"]
    // external lines: (string, string) => array(t) = "diffLines";

    @module("diff")
    external wordsWithSpace_: (string, string) => array<changeObject> = "diffWordsWithSpace"

    let fromChangeObject = obj =>
      if obj["added"] {
        Added(obj["value"])
      } else if obj["removed"] {
        Removed(obj["value"])
      } else {
        NoChange(obj["value"])
      }

    let wordsWithSpace = (a, b) => wordsWithSpace_(a, b)->Array.map(fromChangeObject)

    // given a list of Diff.t, return the first Added or Removed and the character count before it
    let firstChange = diffs => {
      // the count of charactors before the first change occured
      let count = ref(0)
      let change = ref(None)
      diffs->Array.forEach(diff =>
        if Option.isNone(change.contents) {
          switch diff {
          | Added(s) => change := Some(Added(s))
          | Removed(s) => change := Some(Removed(s))
          | NoChange(s) => count := count.contents + String.length(s)
          }
        }
      )

      change.contents->Option.map(change => (change, count.contents))
    }
  }
  // get all filepaths of golden tests (asynchronously)
  let getGoldenFilepaths = directoryPath => {
    let directoryPath = Path.toAbsolute(directoryPath)
    let readdir = N.Fs.readdir |> N.Util.promisify
    let isInFile = Js.String.endsWith(".in")
    let toBasename = path => Node.Path.join2(directoryPath, Node.Path.basename_ext(path, ".in"))
    readdir(. directoryPath) |> then_(paths =>
      paths->Array.keep(isInFile)->Array.map(toBasename)->resolve
    )
  }

  // get all filepaths of golden tests (synchronously)
  let getGoldenFilepathsSync = directoryPath => {
    let directoryPath = Path.toAbsolute(directoryPath)
    let readdir = Node.Fs.readdirSync
    let isInFile = Js.String.endsWith(".in")
    let toBasename = path => Node.Path.join2(directoryPath, Node.Path.basename_ext(path, ".in"))
    readdir(directoryPath)->Array.keep(isInFile)->Array.map(toBasename)
  }

  exception FileMissing(string)

  type filepath = string
  type expected = string
  // parameterized only by 'actual;
  type t<'actual> = Golden(filepath, 'actual, expected)

  // (A -> B) -> Golden A -> Golden B
  let map = (Golden(filepath, actual, expected), f) => Golden(filepath, f(actual), expected)

  // FilePath -> Promise (Golden String)
  let readFile = filepath => {
    let filepath = Path.toAbsolute(filepath)
    let readFile = N.Fs.readFile |> N.Util.promisify

    [readFile(. filepath ++ ".in"), readFile(. filepath ++ ".out")]
    |> all
    |> then_(x =>
      switch x {
      | [input, output] =>
        resolve(
          Golden(
            filepath,
            Node.Buffer.toString(input),
            Strings.normalize(Node.Buffer.toString(output)),
          ),
        )
      | _ => reject(FileMissing(filepath))
      }
    )
  }

  // Golden String -> Promise ()
  let compare = (Golden(_path, actual, expected)) => {
    let actual = Strings.normalize(actual)
    let expected = Strings.normalize(expected)

    Diff.wordsWithSpace(actual, expected)
    ->Diff.firstChange
    ->Option.forEach(((diff, count)) => {
      open Diff
      let value = Diff.getValue(diff)

      // let change =
      //   Js.String.length(value) > 100
      //     ? Js.String.substrAtMost(~from=0, ~length=100, value) ++ " ..."
      //     : value;

      let expected = Js.String.substrAtMost(
        ~from=max(0, count - 50),
        ~length=50 + String.length(value) + 50,
        expected,
      )

      let actual = Js.String.substrAtMost(
        ~from=max(0, count - 50),
        ~length=50 + String.length(value) + 50,
        actual,
      )

      // let message = change =>
      //   "\n\nchange => "
      //   ++ change
      //   ++ "\n\nexpected => "
      //   ++ expected
      //   ++ "\n\nactual   => "
      //   ++ actual;

      switch diff {
      | Added(_) => BsMocha.Assert.fail'(actual, expected)
      // BsMocha.Assert.fail(
      //   message(
      //     " added \""
      //     ++ change
      //     ++ "\"\n at position "
      //     ++ string_of_int(count),
      //   ),
      // )
      | Removed(_) => BsMocha.Assert.fail'(actual, expected)
      //   ~actual: actual,
      //   ~expected: expected,
      //   ~message=change,
      // )

      // message(
      //   " removed \""
      //   ++ change
      //   ++ "\"\n\n at position "
      //   ++ string_of_int(count),
      // ),
      | NoChange(_) => ()
      }
    })
    Js.Promise.resolve()
  }
}

let onUnix = switch N.OS.type_() {
| "Windows_NT" => false
| _ => true
}
