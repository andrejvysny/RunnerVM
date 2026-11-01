/// Which CI system a profile's VMs serve. GitHub profiles are driven by RunnerVM's own scale-set
/// demand; GitLab profiles only supply VMs on request from gitlab-runner, so they have no GitHub
/// scope and must stay invisible to every GitHub code path.
public enum ProfileProvider: String, Codable, Sendable, CaseIterable, Hashable {
  case github
  case gitlab
}
