%global debug_package %{nil}

Name:           bootowser
Version:        0.1.0
Release:        1%{?dist}
Summary:        Locked-down Firefox kiosk that takes the screen at boot

License:        GPL-3.0-or-later
URL:            https://github.com/Pratech1015/Bootowser
Source0:        %{name}-%{version}.tar.gz

BuildRequires:  systemd-devel
Requires:       systemd-libs
Requires:       xorg-server
Requires:       firefox
Requires:       sudo
Recommends:     xorg-x11-utils
Suggests:       mesa-dri-drivers

%description
Bootowser takes over the screen at boot with a real web browser. It runs
Firefox in its built-in kiosk mode, so no tabs, no address bar, no context
menu and no user interface, under a managed policy that disables telemetry,
accounts, updates and developer tools.

It is aimed at single-purpose devices: signage, information kiosks, menu
boards and TV-style displays where a full desktop environment is more than
the device needs.

%package systemd
Summary:        Systemd units for %{name}
BuildArch:      noarch

%description systemd
The systemd units that start the display server and the kiosk browser at boot.

# The browser is a directory, not a binary. Bundle a tree so the kiosk does not
# depend on another package's layout, but fall back to the system install when
# the operator has not staged one.
%global browserdir %{_libdir}/bootowser/bootowser

%prep
%autosetup

%build
# Find a browser install tree: $BOOTOWSER_FIREFOX wins, then a tree staged in
# the source tarball, then the distribution's own firefox package.
# An explicitly requested tree that is not usable is an error, never a silent
# fall back to the system browser: quietly shipping a different browser than
# the operator asked for is worse than failing.
ffdir=""
if [ -n "${BOOTOWSER_FIREFOX:-}" ]; then
  if [ ! -x "${BOOTOWSER_FIREFOX}" ]; then
    echo "error: BOOTOWSER_FIREFOX=${BOOTOWSER_FIREFOX} is not executable" >&2
    exit 1
  fi
  ffdir="$(dirname "$(readlink -f "${BOOTOWSER_FIREFOX}")")"
elif [ -x "%{_sourcedir}/firefox-tree/bootowser" ] \
  || [ -x "%{_sourcedir}/firefox-tree/firefox" ]; then
  ffdir="%{_sourcedir}/firefox-tree"
fi
if [ -z "$ffdir" ]; then
  for c in %{browserdir}/bootowser /usr/lib64/firefox/firefox \
           /usr/lib/firefox/firefox /usr/bin/firefox; do
    if [ -x "$c" ]; then ffdir="$(dirname "$c")"; break; fi
  done
fi
if [ -z "$ffdir" ]; then
  echo "error: no browser installation found" >&2
  echo "       install a Bootowser tree, or set BOOTOWSER_FIREFOX to one" >&2
  exit 1
fi
# A bare libxul.so is not a browser directory; catch that mistake early.
if [ ! -e "$ffdir/omni.ja" ] && [ ! -e "$ffdir/libxul.so" ]; then
  echo "error: $ffdir does not look like a Firefox install directory" >&2
  exit 1
fi
echo "using Firefox tree: $ffdir"

%install
rm -rf %{buildroot}
mkdir -p %{buildroot}%{_prefix}/lib/bootowser
mkdir -p %{buildroot}%{_datadir}/bootowser
mkdir -p %{buildroot}%{_docdir}/bootowser
mkdir -p %{buildroot}%{_unitdir}
mkdir -p %{buildroot}%{_sysconfdir}/sudoers.d
mkdir -p %{buildroot}%{_localstatedir}/lib/bootowser/profile

install -p -m 0755 runtime/bin/bootowser          %{buildroot}%{_prefix}/lib/bootowser/bootowser
install -p -m 0755 runtime/bin/bootowser-xsession %{buildroot}%{_prefix}/lib/bootowser/bootowser-xsession
install -p -m 0644 runtime/xorg/xorg.conf         %{buildroot}%{_datadir}/bootowser/xorg.conf

install -p -m 0644 runtime/lib/systemd/system/bootowser.service          %{buildroot}%{_unitdir}/bootowser.service
install -p -m 0644 runtime/lib/systemd/system/bootowser-xserver.service %{buildroot}%{_unitdir}/bootowser-xserver.service
install -p -m 0644 runtime/lib/systemd/system/bootowser-control.service %{buildroot}%{_unitdir}/bootowser-control.service

install -p -m 0644 runtime/etc/bootowser/bootowser.conf \
                 %{buildroot}%{_sysconfdir}/bootowser/bootowser.conf
install -p -m 0644 runtime/etc/bootowser/control.conf \
                 %{buildroot}%{_sysconfdir}/bootowser/control.conf
install -p -m 0644 runtime/etc/bootowser/policies/managed/policies.json \
                 %{buildroot}%{_sysconfdir}/bootowser/distribution/policies.json

# Control sidecar root hooks: sudo refuses group/world-writable fragments,
# and the rule names exactly this directory.
install -p -m 0440 runtime/lib/sudoers.d/bootowser \
                 %{buildroot}%{_sysconfdir}/sudoers.d/bootowser
install -d -m 0755 %{buildroot}%{_prefix}/lib/bootowser/commands
for f in runtime/lib/bootowser/commands/*.sh; do
  install -p -m 0755 "$f" \
    "%{buildroot}%{_prefix}/lib/bootowser/commands/${f##*/}"
done

# The whole Firefox tree, not just the executable: without omni.ja and the
# shared libraries the browser starts and renders nothing.
#
# The guard matters: if ffdir ever ends up empty, `cp -a "$ffdir"/.` is
# `cp -a "/."` and copies the entire root filesystem into the buildroot.
case "$ffdir" in
  ""|/) echo "error: refusing to copy from '$ffdir'" >&2; exit 1 ;;
esac
# The renamed build ships bootowser; accept the stock name so a tree staged
# before the rebrand still packages. Written as a plain if rather than
# `[ -x .. ] && break`, which would trip `set -e` on the first miss.
exe=""
for cand in bootowser firefox; do
  if [ -x "$ffdir/$cand" ]; then exe="$cand"; break; fi
done
[ -n "$exe" ] || { echo "error: no executable bootowser or firefox in $ffdir" >&2; exit 1; }
echo "bundling browser tree from $ffdir ($exe)"
mkdir -p %{buildroot}%{browserdir}
cp -a "$ffdir"/. %{buildroot}%{browserdir}/

# The control sidecar ships only when the staged tree has it: a system
# firefox fallback or a pre-feature tree has none, and %files must not name
# a file that is not there. The conditional entry goes into a generated
# filelist that %files picks up with -f (always created, possibly empty).
extra_files="%{_builddir}/%{name}-%{version}-extra.files"
: > "$extra_files"
if [ -x "$ffdir/bootowser-control" ]; then
  install -p -m 0755 "$ffdir/bootowser-control" \
                 "%{buildroot}%{_prefix}/lib/bootowser/bootowser-control"
  echo "%{_prefix}/lib/bootowser/bootowser-control" >> "$extra_files"
else
  echo "warning: tree has no bootowser-control; shipping without the control API" >&2
fi

# Gecko reads managed policy from <install dir>/distribution/policies.json,
# so the policy has to sit inside the bundled tree; anywhere else and the kiosk
# starts with no policy applied at all.
install -p -m 0644 runtime/etc/bootowser/policies/managed/policies.json \
                 %{buildroot}%{browserdir}/distribution/policies.json

install -p -m 0644 LICENSE  %{buildroot}%{_docdir}/bootowser/COPYING
install -p -m 0644 README.md %{buildroot}%{_docdir}/bootowser/README.md
install -p -m 0644 docs/security.md %{buildroot}%{_docdir}/bootowser/security.md

%pre
getent group bootowser >/dev/null || groupadd -r bootowser
getent passwd bootowser >/dev/null || \
  useradd -r -g bootowser -d /var/lib/bootowser -s /sbin/nologin \
          -c "Bootowser kiosk browser" bootowser
usermod -a -G video,render bootowser >/dev/null 2>&1 || :

%post systemd
%systemd_post bootowser-xserver.service
%systemd_post bootowser.service
%systemd_post bootowser-control.service

%preun systemd
%systemd_preun bootowser-xserver.service
%systemd_preun bootowser.service
%systemd_preun bootowser-control.service

%postun systemd
%systemd_postun_with_restart bootowser.service
%systemd_postun_with_restart bootowser-control.service

%files -f %{_builddir}/%{name}-%{version}-extra.files
%license LICENSE
%doc %{_docdir}/bootowser/README.md
%doc %{_docdir}/bootowser/security.md
%{_prefix}/lib/bootowser/bootowser
%{_prefix}/lib/bootowser/bootowser-xsession
%dir %{_prefix}/lib/bootowser/commands
%{_prefix}/lib/bootowser/commands/*.sh
%{_datadir}/bootowser/xorg.conf
%config(noreplace) %{_sysconfdir}/bootowser/bootowser.conf
%config(noreplace) %{_sysconfdir}/bootowser/control.conf
%config(noreplace) %{_sysconfdir}/bootowser/distribution/policies.json
%attr(0440,root,root) %{_sysconfdir}/sudoers.d/bootowser
%attr(0700,bootowser,bootowser) %dir %{_localstatedir}/lib/bootowser/profile

%files systemd
%{_unitdir}/bootowser.service
%{_unitdir}/bootowser-xserver.service
%{_unitdir}/bootowser-control.service

%changelog
* Wed Sep 30 2026 Pratech1015 <pragyan.krish3@gmail.com> - 0.1.0-1
- Initial release: Firefox kiosk runtime, systemd units, minimal X server
  configuration, managed policy lockdown. No boot splash is shipped; the
  browser waits for the system's existing Plymouth theme to finish.