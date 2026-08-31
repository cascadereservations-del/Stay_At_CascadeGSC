import { StrictMode } from 'react'
import { createRoot } from 'react-dom/client'
import './complete.css'
import './outlook.css'
import './analytics.css'
import './financial-health.css'
import CompleteApp from './CompleteApp.tsx'

createRoot(document.getElementById('root')!).render(
  <StrictMode>
    <CompleteApp />
  </StrictMode>,
)
