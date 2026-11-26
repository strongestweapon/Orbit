"""Export the default OSC contract from the native routing types."""
from pathlib import Path
import subprocess

def export_osc_reference():
    root=Path(__file__).resolve().parents[2]
    build=root/'.build/osc-reference';build.mkdir(parents=True,exist_ok=True)
    binary=build/'export-osc-reference'
    sources=[root/'OrbitApp/Sources/ParameterRouting.swift',root/'OrbitApp/Sources/InstallationSettings.swift',root/'OrbitApp/Tools/export_osc_reference.swift']
    if not binary.exists() or any(p.stat().st_mtime>binary.stat().st_mtime for p in sources):
        subprocess.run(['xcrun','swiftc','-O','-module-cache-path',str(build/'modules'),*map(str,sources),'-o',str(binary)],check=True)
    subprocess.run([str(binary),str(root/'OrbitShaders/config/scenes.json'),str(root/'OrbitShaders/config/osc-mappings.example.json')],check=True)

if __name__=='__main__': export_osc_reference()
