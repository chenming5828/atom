require 'window'
window.setUpEnvironment()

nakedLoad 'jasmine-jquery'
$ = require 'jquery'
_ = require 'underscore'
Keymap = require 'keymap'
Config = require 'config'
Point = require 'point'
Project = require 'project'
Directory = require 'directory'
File = require 'file'
Editor = require 'editor'
TokenizedBuffer = require 'tokenized-buffer'
fs = require 'fs-utils'
RootView = require 'root-view'
Git = require 'git'
requireStylesheet "jasmine.css"
fixturePackagesPath = fs.resolveOnLoadPath('fixtures/packages')
keymap.loadBundledKeymaps()
[bindingSetsToRestore, bindingSetsByFirstKeystrokeToRestore] = []

$(window).on 'core:close', -> window.close()
$(window).on 'toggle-dev-tools', (e) -> atom.toggleDevTools()
$('html,body').css('overflow', 'auto')

jasmine.getEnv().addEqualityTester(_.isEqual) # Use underscore's definition of equality for toEqual assertions
jasmine.getEnv().defaultTimeoutInterval = 5000

beforeEach ->
  jQuery.fx.off = true
  window.project = new Project(fs.resolveOnLoadPath('fixtures'))
  window.git = Git.open(project.getPath())
  window.project.on 'path-changed', ->
    window.git?.destroy()
    window.git = Git.open(window.project.getPath())

  window.resetTimeouts()
  atom.atomPackageStates = {}
  atom.loadedPackages = []

  # used to reset keymap after each spec
  bindingSetsToRestore = _.clone(keymap.bindingSets)
  bindingSetsByFirstKeystrokeToRestore = _.clone(keymap.bindingSetsByFirstKeystroke)

  # reset config before each spec; don't load or save from/to `config.json`
  window.config = new Config()
  spyOn(config, 'load')
  spyOn(config, 'save')
  config.set "editor.fontFamily", "Courier"
  config.set "editor.fontSize", 16
  config.set "editor.autoIndent", false
  config.set "core.disabledPackages", ["package-that-throws-an-exception"]

  # make editor display updates synchronous
  spyOn(Editor.prototype, 'requestDisplayUpdate').andCallFake -> @updateDisplay()
  spyOn(RootView.prototype, 'setTitle').andCallFake (@title) ->
  spyOn(window, "setTimeout").andCallFake window.fakeSetTimeout
  spyOn(window, "clearTimeout").andCallFake window.fakeClearTimeout
  spyOn(File.prototype, "detectResurrectionAfterDelay").andCallFake -> @detectResurrection()

  # make tokenization synchronous
  TokenizedBuffer.prototype.chunkSize = Infinity
  spyOn(TokenizedBuffer.prototype, "tokenizeInBackground").andCallFake -> @tokenizeNextChunk()

  pasteboardContent = 'initial pasteboard content'
  spyOn($native, 'writeToPasteboard').andCallFake (text) -> pasteboardContent = text
  spyOn($native, 'readFromPasteboard').andCallFake -> pasteboardContent

afterEach ->
  keymap.bindingSets = bindingSetsToRestore
  keymap.bindingSetsByFirstKeystrokeToRestore = bindingSetsByFirstKeystrokeToRestore
  if rootView?
    rootView.deactivate?()
    window.rootView = null
  if project?
    project.destroy()
    window.project = null
  if git?
    git.destroy()
    window.git = null
  $('#jasmine-content').empty()
  ensureNoPathSubscriptions()
  atom.pendingModals = [[]]
  atom.presentingModal = false
  waits(0) # yield to ui thread to make screen update more frequently

window.loadPackage = (name, options) ->
  Package = require 'package'
  packagePath = _.find atom.getPackagePaths(), (packagePath) -> fs.base(packagePath) == name
  if pack = Package.build(packagePath)
    pack.load(options)
    atom.loadedPackages.push(pack)
  pack

# Specs rely on TextMate bundles (but not atom packages)
window.loadTextMatePackages = ->
  TextMatePackage = require 'text-mate-package'
  config.packageDirPaths.unshift(fixturePackagesPath)
  window.textMatePackages = []
  for path in atom.getPackagePaths() when TextMatePackage.testName(path)
    window.textMatePackages.push window.loadPackage(fs.base(path))

window.loadTextMatePackages()

ensureNoPathSubscriptions = ->
  watchedPaths = $native.getWatchedPaths()
  $native.unwatchAllPaths()
  if watchedPaths.length > 0
    throw new Error("Leaking subscriptions for paths: " + watchedPaths.join(", "))

emitObject = jasmine.StringPrettyPrinter.prototype.emitObject
jasmine.StringPrettyPrinter.prototype.emitObject = (obj) ->
  if obj.inspect
    @append obj.inspect()
  else
    emitObject.call(this, obj)

jasmine.unspy = (object, methodName) ->
  throw new Error("Not a spy") unless object[methodName].originalValue?
  object[methodName] = object[methodName].originalValue

window.keyIdentifierForKey = (key) ->
  if key.length > 1 # named key
    key
  else
    charCode = key.toUpperCase().charCodeAt(0)
    "U+00" + charCode.toString(16)

window.keydownEvent = (key, properties={}) ->
  properties = $.extend({originalEvent: { keyIdentifier: keyIdentifierForKey(key) }}, properties)
  $.Event("keydown", properties)

window.mouseEvent = (type, properties) ->
  if properties.point
    {point, editor} = properties
    {top, left} = @pagePixelPositionForPoint(editor, point)
    properties.pageX = left + 1
    properties.pageY = top + 1
  properties.originalEvent ?= {detail: 1}
  $.Event type, properties

window.clickEvent = (properties={}) ->
  window.mouseEvent("click", properties)

window.mousedownEvent = (properties={}) ->
  window.mouseEvent('mousedown', properties)

window.mousemoveEvent = (properties={}) ->
  window.mouseEvent('mousemove', properties)

window.waitsForPromise = (args...) ->
  if args.length > 1
    { shouldReject } = args[0]
  else
    shouldReject = false
  fn = _.last(args)

  window.waitsFor (moveOn) ->
    promise = fn()
    if shouldReject
      promise.fail(moveOn)
      promise.done ->
        jasmine.getEnv().currentSpec.fail("Expected promise to be rejected, but it was resolved")
        moveOn()
    else
      promise.done(moveOn)
      promise.fail (error) ->
        jasmine.getEnv().currentSpec.fail("Expected promise to be resolved, but it was rejected with #{jasmine.pp(error)}")
        moveOn()

window.resetTimeouts = ->
  window.now = 0
  window.timeoutCount = 0
  window.timeouts = []

window.fakeSetTimeout = (callback, ms) ->
  id = ++window.timeoutCount
  window.timeouts.push([id, window.now + ms, callback])
  id

window.fakeClearTimeout = (idToClear) ->
  window.timeouts = window.timeouts.filter ([id]) -> id != idToClear

window.advanceClock = (delta=1) ->
  window.now += delta
  callbacks = []

  window.timeouts = window.timeouts.filter ([id, strikeTime, callback]) ->
    if strikeTime <= window.now
      callbacks.push(callback)
      false
    else
      true

  callback() for callback in callbacks

window.pagePixelPositionForPoint = (editor, point) ->
  point = Point.fromObject point
  top = editor.renderedLines.offset().top + point.row * editor.lineHeight
  left = editor.renderedLines.offset().left + point.column * editor.charWidth - editor.renderedLines.scrollLeft()
  { top, left }

window.tokensText = (tokens) ->
  _.pluck(tokens, 'value').join('')

window.setEditorWidthInChars = (editor, widthInChars, charWidth=editor.charWidth) ->
  editor.width(charWidth * widthInChars + editor.gutter.outerWidth())
  $(window).trigger 'resize' # update width of editor's on-screen lines

window.setEditorHeightInLines = (editor, heightInChars, charHeight=editor.lineHeight) ->
  editor.height(charHeight * heightInChars + editor.renderedLines.position().top)
  $(window).trigger 'resize' # update editor's on-screen lines

$.fn.resultOfTrigger = (type) ->
  event = $.Event(type)
  this.trigger(event)
  event.result

$.fn.enableKeymap = ->
  @on 'keydown', (e) => window.keymap.handleKeyEvent(e)

$.fn.attachToDom = ->
  $('#jasmine-content').append(this)

$.fn.simulateDomAttachment = ->
  $('<html>').append(this)

$.fn.textInput = (data) ->
  this.each ->
    event = document.createEvent('TextEvent')
    event.initTextEvent('textInput', true, true, window, data)
    event = jQuery.event.fix(event)
    $(this).trigger(event)

unless fs.md5ForPath(require.resolve('fixtures/sample.js')) == "dd38087d0d7e3e4802a6d3f9b9745f2b"
  throw "Sample.js is modified"
