import { Label } from '@primer/react'
import { PlayIcon } from '@primer/octicons-react'
import { Link, Route, Switch } from 'wouter'
import { JobView } from './views/JobView'
import { RunList } from './views/RunList'
import { RunnerList } from './views/RunnerList'
import { RunPage } from './views/RunPage'

// The routes (R16): RunList (U5), RunPage (U6), JobView (U4), RunnerList (U8).

function NotFoundPage() {
  return (
    <div className="ar-box">
      <div className="ar-blankslate">
        <h1 className="ar-blankslate__title">Page not found</h1>
        <p className="ar-blankslate__body">
          There is nothing at this address. <Link href="/">Go to all workflow runs</Link>.
        </p>
      </div>
    </div>
  )
}

const dataSource = import.meta.env.VITE_DATA_SOURCE === 'http' ? 'http' : 'fake'

export default function App() {
  return (
    <>
      <header className="ar-app-header">
        <Link href="/" className="ar-app-header__brand">
          <PlayIcon size={24} />
          Zig runner
        </Link>
        <span className="ar-app-header__section">Actions</span>
        <Link href="/runners" className="ar-app-header__link">
          Runners
        </Link>
        <span className="ar-app-header__spacer" />
        {dataSource === 'fake' && <Label variant="attention">Fake data</Label>}
      </header>
      <main className="ar-page">
        <Switch>
          <Route path="/">
            <RunList />
          </Route>
          <Route path="/runners">
            <RunnerList />
          </Route>
          <Route path="/runs/:id">
            {(params) => <RunPage key={params.id} runId={Number(params.id)} />}
          </Route>
          <Route path="/runs/:runId/jobs/:jobId">
            {(params) => (
              <JobView key={`${params.runId}/${params.jobId}`} runId={Number(params.runId)} jobId={Number(params.jobId)} />
            )}
          </Route>
          <Route>
            <NotFoundPage />
          </Route>
        </Switch>
      </main>
    </>
  )
}
