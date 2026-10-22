import { App } from './App.js'
import WebGPU from 'three/examples/jsm/capabilities/WebGPU.js'

const loadingEl = document.getElementById('loading')
const canvas = document.getElementById('canvas')

let app = null

async function init() {
  if (!WebGPU.isAvailable()) {
    loadingEl.innerHTML = '<p style="color:#fff">WebGPU is not available on your device or browser.</p>'
    return
  }

  app = new App(canvas)
  await app.init()

  // Hide loading overlay
  loadingEl.style.display = 'none'

  // Fade in scene
  app.fadeIn(1000)

  // Start intro build animation
  app.city.startIntroAnimation(app.camera, app.controls, 4)
}

init()
