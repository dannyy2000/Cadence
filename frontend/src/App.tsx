import { Nav } from './components/Nav'
import { Hero } from './components/Hero'
import { Problem } from './components/Problem'
import { HowItWorks } from './components/HowItWorks'
import { Proof } from './components/Proof'
import { LiveQueue } from './components/LiveQueue'
import { Faq } from './components/Faq'
import { Footer } from './components/Footer'
import './App.css'

export default function App() {
  return (
    <div className="page">
      <Nav />
      <Hero />
      <Problem />
      <HowItWorks />
      <Proof />
      <LiveQueue />
      <Faq />
      <Footer />
    </div>
  )
}
