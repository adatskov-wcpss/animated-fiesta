#!/bin/bash

set -u

# Configuration
PORTAL_PORT=6700
INSTANCES_DIR="/tmp/selkies_instances"
LOG_DIR="/tmp/selkies_logs"
STATE_FILE="/tmp/selkies_state.json"

# Available Selkies Distros
declare -A DISTROS=(
    [1]="Debian Bookworm|lscr.io/linuxserver/baseimage-selkies:debianbookworm"
    [2]="Ubuntu Desktop (22.04)|lscr.io/linuxserver/baseimage-selkies:ubuntudesktop-22.04"
    [3]="Ubuntu Desktop (24.04)|lscr.io/linuxserver/baseimage-selkies:ubuntudesktop-24.04"
    [4]="Zorion OS|lscr.io/linuxserver/baseimage-selkies:zorionosdesktop"
    [5]="Alpine Linux|lscr.io/linuxserver/baseimage-selkies:alpine"
    [6]="Rocky Linux|lscr.io/linuxserver/baseimage-selkies:rocky"
    [7]="Alma Linux|lscr.io/linuxserver/baseimage-selkies:almalinux"
    [8]="Fedora|lscr.io/linuxserver/baseimage-selkies:fedora"
    [9]="Arch Linux|lscr.io/linuxserver/baseimage-selkies:arch"
    [10]="OpenSUSE|lscr.io/linuxserver/baseimage-selkies:opensuse"
    [11]="CentOS|lscr.io/linuxserver/baseimage-selkies:centos"
    [12]="Kali Linux|lscr.io/linuxserver/baseimage-selkies:kali"
    [13]="Parrot OS|lscr.io/linuxserver/baseimage-selkies:parroos"
)

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# Initialize directories
init_dirs() {
    mkdir -p "$INSTANCES_DIR" "$LOG_DIR"
}

# Show URLs helper
show_urls() {
    local container=$1
    local log_file="/tmp/serveo_${container}.log"
    
    if [ ! -f "$log_file" ] || ! grep -q "serveousercontent" "$log_file" 2>/dev/null; then
        [ -f "/tmp/serveo_${container}.pid" ] && kill $(cat "/tmp/serveo_${container}.pid") 2>/dev/null
        rm -f "$log_file"
        
        # Start serveo tunnel in background
        nohup ssh -o StrictHostKeyChecking=no -o ServerAliveInterval=30 -R 80:localhost:3000 serveo.net > "$log_file" 2>&1 & 
        echo $! > "/tmp/serveo_${container}.pid"
        
        # Wait for URL to appear
        for i in {1..10}; do 
            grep -q "serveousercontent" "$log_file" 2>/dev/null && break
            sleep 0.5
        done
    fi
    
    echo -e "\n${CYAN}=== Selkies Access URLs ($container) ===${NC}"
    echo -e "${GREEN}Local URL:${NC}  http://localhost:3000"
    local serveo_url=$(grep -o -E "https?://[a-zA-Z0-9.-]+\.serveousercontent\.com/?" "$log_file" 2>/dev/null | head -n 1)
    if [ -n "$serveo_url" ]; then
        echo -e "${GREEN}Serveo URL:${NC} $serveo_url"
    else
        echo -e "${YELLOW}Serveo URL:${NC} (waiting for tunnel...)"
    fi
}

# Display main menu
show_main_menu() {
    clear
    echo -e "${BLUE}╔════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║   ${BOLD}Selkies Multi-Distro Launcher v2.0${NC}${BLUE}                  ║${NC}"
    echo -e "${BLUE}╚════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "${CYAN}${BOLD}Available Distros:${NC}"
    for key in "${!DISTROS[@]}"; do
        IFS='|' read -r name image <<< "${DISTROS[$key]}"
        printf "  ${YELLOW}%2d${NC}) %s\n" "$key" "$name"
    done
    echo ""
    echo -e "${CYAN}${BOLD}Management Options:${NC}"
    echo "  ${YELLOW}14${NC}) Start Web Portal (Port $PORTAL_PORT)"
    echo "  ${YELLOW}15${NC}) List Running Instances"
    echo "  ${YELLOW}16${NC}) Stop All Instances"
    echo "  ${YELLOW}0${NC}) Exit"
    echo ""
}

# Get user input with validation
get_menu_choice() {
    local choice
    while true; do
        read -p "$(echo -e ${CYAN}Enter your choice:${NC} )" choice
        
        # Validate input is a number
        if ! [[ "$choice" =~ ^[0-9]+$ ]]; then
            echo -e "${RED}✗ Invalid input. Please enter a number.${NC}"
            continue
        fi
        
        # Validate choice is in valid range
        if [ "$choice" -eq 0 ] || [ "$choice" -eq 14 ] || [ "$choice" -eq 15 ] || [ "$choice" -eq 16 ]; then
            echo "$choice"
            return 0
        elif [ "$choice" -ge 1 ] && [ "$choice" -le 13 ]; then
            echo "$choice"
            return 0
        else
            echo -e "${RED}✗ Invalid choice. Please select a valid option.${NC}"
        fi
    done
}

# Start container with live output
start_container() {
    local distro_key=$1
    
    if [ ! -v "DISTROS[$distro_key]" ]; then
        echo -e "${RED}✗ Invalid distro selection${NC}"
        read -p "Press Enter to continue..."
        return 1
    fi
    
    local distro_name distro_image
    IFS='|' read -r distro_name distro_image <<< "${DISTROS[$distro_key]}"
    
    local container_name="selkies_${distro_key}_$(date +%s)"
    local port=$((3000 + distro_key))
    local log_file="$LOG_DIR/${container_name}.log"
    
    clear
    echo -e "\n${CYAN}${BOLD}Starting: $distro_name${NC}"
    echo -e "${YELLOW}Container:${NC} $container_name"
    echo -e "${YELLOW}Port:${NC} $port"
    echo -e "${YELLOW}Image:${NC} $distro_image"
    echo ""
    
    # Pull image with live output
    echo -e "${CYAN}${BOLD}Pulling image...${NC}"
    if docker pull "$distro_image" 2>&1 | tee -a "$log_file" | sed 's/^/  /'; then
        echo -e "${GREEN}✓ Image pulled successfully${NC}\n"
    else
        echo -e "${RED}✗ Failed to pull image${NC}"
        read -p "Press Enter to continue..."
        return 1
    fi
    
    # Run container with live output
    echo -e "${CYAN}${BOLD}Starting container...${NC}"
    local container_id
    if container_id=$(docker run -d \
        --name "$container_name" \
        -p "$port:3000" \
        -p "$((port+1)):3001" \
        --shm-size="5gb" \
        -v /tmp:/tmp \
        -e PUID=1000 \
        -e PGID=1000 \
        --restart unless-stopped \
        "$distro_image" 2>&1 | tee -a "$log_file"); then
        echo -e "${GREEN}✓ Container started successfully${NC}"
        echo -e "Container ID: ${YELLOW}$container_id${NC}\n"
        
        # Wait a moment for container to be ready
        sleep 2
        
        # Show container logs
        echo -e "${CYAN}${BOLD}Container Status:${NC}"
        docker logs "$container_name" 2>&1 | tail -10 | sed 's/^/  /'
        
        # Show URLs
        show_urls "$container_name"
        
        # Save instance info
        save_instance_info "$container_name" "$distro_name" "$port" "$distro_image"
    else
        echo -e "${RED}✗ Failed to start container${NC}"
        read -p "Press Enter to continue..."
        return 1
    fi
    
    read -p "Press Enter to continue..."
}

# Save instance info to state file
save_instance_info() {
    local container=$1
    local name=$2
    local port=$3
    local image=$4
    
    if [ ! -f "$STATE_FILE" ]; then
        echo '{"instances":[]}' > "$STATE_FILE"
    fi
    
    # Simple manifest append
    echo "$container|$name|$port|$image" >> "$INSTANCES_DIR/manifest.txt"
}

# List running instances
list_instances() {
    clear
    echo -e "${BLUE}${BOLD}Running Instances:${NC}\n"
    
    local count=$(docker ps --filter "name=selkies_" --format "{{.Names}}" 2>/dev/null | wc -l)
    
    if [ $count -eq 0 ]; then
        echo -e "${YELLOW}No instances running${NC}"
    else
        docker ps --filter "name=selkies_" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" 2>/dev/null | while IFS=$'\t' read -r name status ports; do
            echo -e "${GREEN}${BOLD}$name${NC}"
            echo "  Status: $status"
            echo "  Ports: $ports"
            echo ""
        done
    fi
    
    if [ -f "$INSTANCES_DIR/manifest.txt" ]; then
        local total=$(wc -l < "$INSTANCES_DIR/manifest.txt" 2>/dev/null || echo 0)
        echo -e "${CYAN}Total instances launched: ${YELLOW}$total${NC}"
    fi
    
    echo ""
    read -p "Press Enter to continue..."
}

# Stop all instances
stop_all_instances() {
    clear
    echo -e "${YELLOW}${BOLD}Stopping all instances...${NC}\n"
    
    local containers=$(docker ps --filter "name=selkies_" --format "{{.Names}}" 2>/dev/null)
    
    if [ -z "$containers" ]; then
        echo -e "${YELLOW}No instances running${NC}"
    else
        echo "$containers" | while read -r container; do
            echo -e "${CYAN}Stopping $container...${NC}"
            docker stop "$container" 2>&1 | sed 's/^/  /'
        done
        echo -e "${GREEN}✓ All instances stopped${NC}"
    fi
    
    echo ""
    read -p "Press Enter to continue..."
}

# Start web portal for instance management
start_web_portal() {
    clear
    echo -e "\n${CYAN}${BOLD}Starting Web Portal on port $PORTAL_PORT...${NC}"
    
    # Create a simple web server container
    local portal_container="selkies-portal-$RANDOM"
    
    # HTML content for management interface
    local html_file="$INSTANCES_DIR/index.html"
    
    cat > "$html_file" << 'EOF'
<!DOCTYPE html>
<html>
<head>
    <title>Selkies Instance Manager</title>
    <style>
        * { margin: 0; padding: 0; box-sizing: border-box; }
        body { 
            font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif;
            background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
            min-height: 100vh;
            padding: 20px;
        }
        .container {
            max-width: 1200px;
            margin: 0 auto;
            background: white;
            border-radius: 10px;
            box-shadow: 0 10px 40px rgba(0,0,0,0.3);
            overflow: hidden;
        }
        header {
            background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
            color: white;
            padding: 30px;
            text-align: center;
        }
        h1 { font-size: 2.5em; margin-bottom: 10px; }
        .subtitle { opacity: 0.9; font-size: 1.1em; }
        .content {
            padding: 40px;
        }
        .section {
            margin-bottom: 40px;
        }
        .section h2 {
            color: #667eea;
            margin-bottom: 20px;
            padding-bottom: 10px;
            border-bottom: 2px solid #667eea;
        }
        .distro-grid {
            display: grid;
            grid-template-columns: repeat(auto-fill, minmax(250px, 1fr));
            gap: 15px;
            margin-bottom: 20px;
        }
        .distro-card {
            background: #f8f9fa;
            border: 2px solid #e0e0e0;
            border-radius: 8px;
            padding: 20px;
            cursor: pointer;
            transition: all 0.3s ease;
            text-align: center;
        }
        .distro-card:hover {
            border-color: #667eea;
            background: #f0f3ff;
            transform: translateY(-5px);
            box-shadow: 0 5px 15px rgba(102, 126, 234, 0.3);
        }
        .distro-card button {
            background: #667eea;
            color: white;
            border: none;
            padding: 10px 20px;
            border-radius: 5px;
            cursor: pointer;
            font-weight: bold;
            width: 100%;
            margin-top: 10px;
        }
        .distro-card button:hover {
            background: #764ba2;
        }
        .instances {
            background: #f8f9fa;
            border-radius: 8px;
            padding: 20px;
        }
        .instance-item {
            background: white;
            border-left: 4px solid #667eea;
            padding: 15px;
            margin-bottom: 10px;
            border-radius: 4px;
            display: flex;
            justify-content: space-between;
            align-items: center;
        }
        .status {
            display: inline-block;
            padding: 5px 10px;
            border-radius: 4px;
            font-size: 0.9em;
            font-weight: bold;
        }
        .status.running { background: #d4edda; color: #155724; }
        .status.stopped { background: #f8d7da; color: #721c24; }
        .btn-group {
            display: flex;
            gap: 10px;
        }
        button {
            background: #667eea;
            color: white;
            border: none;
            padding: 10px 20px;
            border-radius: 5px;
            cursor: pointer;
            font-weight: bold;
            transition: background 0.3s ease;
        }
        button:hover {
            background: #764ba2;
        }
        button.danger {
            background: #dc3545;
        }
        button.danger:hover {
            background: #c82333;
        }
        .loading {
            display: none;
            text-align: center;
            padding: 20px;
            color: #667eea;
        }
        .spinner {
            border: 3px solid #f3f3f3;
            border-top: 3px solid #667eea;
            border-radius: 50%;
            width: 30px;
            height: 30px;
            animation: spin 1s linear infinite;
            margin: 0 auto 10px;
        }
        @keyframes spin {
            0% { transform: rotate(0deg); }
            100% { transform: rotate(360deg); }
        }
        .info-banner {
            background: #e7f3ff;
            border-left: 4px solid #2196F3;
            padding: 15px;
            margin-bottom: 20px;
            border-radius: 4px;
        }
    </style>
</head>
<body>
    <div class="container">
        <header>
            <h1>🐧 Selkies Instance Manager</h1>
            <p class="subtitle">Multi-Distro Linux Desktop Environment Portal</p>
        </header>
        <div class="content">
            <div class="info-banner">
                <strong>ℹ️ Tip:</strong> Launch new instances, monitor running containers, and access them via local or Serveo URLs.
            </div>
            
            <div class="section">
                <h2>Launch New Instance</h2>
                <div class="distro-grid" id="distroGrid"></div>
            </div>
            
            <div class="section">
                <h2>Running Instances</h2>
                <div class="loading" id="loading">
                    <div class="spinner"></div>
                    <p>Loading instances...</p>
                </div>
                <div class="instances" id="instances">
                    <p style="color: #999;">No instances running</p>
                </div>
            </div>
            
            <div class="section">
                <h2>Management</h2>
                <button onclick="refreshInstances()">🔄 Refresh</button>
                <button class="danger" onclick="stopAll()">⛔ Stop All Instances</button>
            </div>
        </div>
    </div>

    <script>
        const distros = {
            "debian-bookworm": "Debian Bookworm",
            "ubuntu-22.04": "Ubuntu Desktop 22.04",
            "ubuntu-24.04": "Ubuntu Desktop 24.04",
            "zorion-os": "Zorion OS",
            "alpine": "Alpine Linux",
            "rocky": "Rocky Linux",
            "alma": "Alma Linux",
            "fedora": "Fedora",
            "arch": "Arch Linux",
            "opensuse": "OpenSUSE",
            "centos": "CentOS",
            "kali": "Kali Linux",
            "parrot": "Parrot OS"
        };

        function loadDistros() {
            const grid = document.getElementById('distroGrid');
            Object.entries(distros).forEach(([key, name]) => {
                const card = document.createElement('div');
                card.className = 'distro-card';
                card.innerHTML = `
                    <h3>🐧 ${name}</h3>
                    <button onclick="launchInstance('${key}')">Launch</button>
                `;
                grid.appendChild(card);
            });
        }

        function launchInstance(distro) {
            showLoading(true);
            fetch('/api/launch', {
                method: 'POST',
                headers: {'Content-Type': 'application/json'},
                body: JSON.stringify({distro: distro})
            })
            .then(r => r.json())
            .then(data => {
                alert(`Launched: ${data.container}\nPort: ${data.port}`);
                refreshInstances();
            })
            .catch(e => alert('Error: ' + e))
            .finally(() => showLoading(false));
        }

        function refreshInstances() {
            showLoading(true);
            fetch('/api/instances')
                .then(r => r.json())
                .then(data => {
                    const container = document.getElementById('instances');
                    if (data.instances.length === 0) {
                        container.innerHTML = '<p style="color: #999;">No instances running</p>';
                    } else {
                        container.innerHTML = data.instances.map(inst => `
                            <div class="instance-item">
                                <div>
                                    <strong>${inst.name}</strong><br>
                                    <small>Port: ${inst.port} | Image: ${inst.image}</small>
                                </div>
                                <div class="btn-group">
                                    <span class="status running">${inst.status}</span>
                                    <button onclick="openInstance('http://localhost:${inst.port}')">Open</button>
                                    <button class="danger" onclick="stopInstance('${inst.name}')">Stop</button>
                                </div>
                            </div>
                        `).join('');
                    }
                })
                .catch(e => console.error(e))
                .finally(() => showLoading(false));
        }

        function openInstance(url) {
            window.open(url, '_blank');
        }

        function stopInstance(name) {
            if (confirm(`Stop ${name}?`)) {
                fetch('/api/stop', {
                    method: 'POST',
                    headers: {'Content-Type': 'application/json'},
                    body: JSON.stringify({container: name})
                }).then(() => refreshInstances());
            }
        }

        function stopAll() {
            if (confirm('Stop all instances?')) {
                fetch('/api/stop-all', {method: 'POST'})
                    .then(() => refreshInstances());
            }
        }

        function showLoading(show) {
            document.getElementById('loading').style.display = show ? 'block' : 'none';
        }

        loadDistros();
        refreshInstances();
        setInterval(refreshInstances, 5000);
    </script>
</body>
</html>
EOF

    # Create simple Node.js server
    local server_file="$INSTANCES_DIR/server.js"
    
    cat > "$server_file" << 'NODEEOF'
const http = require('http');
const fs = require('fs');
const path = require('path');
const { spawn } = require('child_process');

const PORT = process.env.PORT || 6700;

const server = http.createServer((req, res) => {
    res.setHeader('Access-Control-Allow-Origin', '*');
    res.setHeader('Access-Control-Allow-Methods', 'GET, POST, OPTIONS');
    res.setHeader('Access-Control-Allow-Headers', 'Content-Type');

    if (req.method === 'OPTIONS') {
        res.writeHead(200);
        res.end();
        return;
    }

    if (req.url === '/' && req.method === 'GET') {
        const html = fs.readFileSync(path.join(__dirname, 'index.html'), 'utf8');
        res.writeHead(200, {'Content-Type': 'text/html'});
        res.end(html);
    } else if (req.url === '/api/instances' && req.method === 'GET') {
        const proc = spawn('docker', ['ps', '--filter', 'name=selkies_', '--format', '{{.Names}}|{{.Status}}|{{.Ports}}']);
        let output = '';
        
        proc.stdout.on('data', (data) => { output += data.toString(); });
        proc.on('close', () => {
            const instances = output.trim().split('\n').filter(l => l).map(line => {
                const [name, status, ports] = line.split('|');
                const portMatch = ports.match(/:(\d+)->/);
                return {
                    name,
                    status: status.includes('Up') ? 'Running' : 'Stopped',
                    port: portMatch ? portMatch[1] : '3000',
                    image: 'selkies'
                };
            });
            res.writeHead(200, {'Content-Type': 'application/json'});
            res.end(JSON.stringify({instances}));
        });
    } else if (req.url === '/api/launch' && req.method === 'POST') {
        let body = '';
        req.on('data', chunk => { body += chunk.toString(); });
        req.on('end', () => {
            try {
                const {distro} = JSON.parse(body);
                const container = `selkies_${distro}_${Date.now()}`;
                const port = 3000 + Math.floor(Math.random() * 100);
                
                spawn('docker', ['run', '-d', '--name', container, '-p', `${port}:3000`, '--shm-size=5gb', `lscr.io/linuxserver/baseimage-selkies:${distro}`]);
                
                res.writeHead(200, {'Content-Type': 'application/json'});
                res.end(JSON.stringify({container, port, status: 'Starting'}));
            } catch(e) {
                res.writeHead(400, {'Content-Type': 'application/json'});
                res.end(JSON.stringify({error: e.message}));
            }
        });
    } else if (req.url === '/api/stop' && req.method === 'POST') {
        let body = '';
        req.on('data', chunk => { body += chunk.toString(); });
        req.on('end', () => {
            const {container} = JSON.parse(body);
            spawn('docker', ['stop', container]);
            res.writeHead(200, {'Content-Type': 'application/json'});
            res.end(JSON.stringify({status: 'Stopping'}));
        });
    } else if (req.url === '/api/stop-all' && req.method === 'POST') {
        const proc = spawn('docker', ['ps', '--filter', 'name=selkies_', '-q']);
        let cids = '';
        proc.stdout.on('data', (data) => { cids += data.toString(); });
        proc.on('close', () => {
            cids.trim().split('\n').forEach(cid => {
                if(cid) spawn('docker', ['stop', cid]);
            });
            res.writeHead(200, {'Content-Type': 'application/json'});
            res.end(JSON.stringify({status: 'Stopping all'}));
        });
    } else {
        res.writeHead(404);
        res.end('Not found');
    }
});

server.listen(PORT, () => {
    console.log(`\n🚀 Selkies Portal running on http://localhost:${PORT}\n`);
});
NODEEOF

    # Start portal with Node.js
    if docker run -d \
        --name "$portal_container" \
        -p "$PORTAL_PORT:$PORTAL_PORT" \
        -v "$INSTANCES_DIR:/app" \
        -w /app \
        -e PORT="$PORTAL_PORT" \
        node:18-alpine \
        node server.js > /dev/null 2>&1; then
        echo -e "${GREEN}✓ Web Portal started successfully!${NC}"
        echo -e "${CYAN}Access at:${NC} ${YELLOW}http://localhost:$PORTAL_PORT${NC}"
        echo ""
        echo -e "${CYAN}${BOLD}Features:${NC}"
        echo "  • Launch instances from web interface"
        echo "  • Real-time instance monitoring"
        echo "  • Quick access to running containers"
        echo "  • Stop individual or all instances"
        echo ""
    else
        echo -e "${RED}✗ Failed to start portal${NC}"
    fi
    
    read -p "Press Enter to continue..."
}

# Main loop
main() {
    init_dirs
    
    # Check for Docker
    if ! command -v docker &> /dev/null; then
        echo -e "${RED}✗ Docker is not installed!${NC}"
        exit 1
    fi
    
    while true; do
        show_main_menu
        
        # Get user choice with validation
        choice=$(get_menu_choice)
        
        case "$choice" in
            0)
                echo -e "\n${CYAN}Goodbye!${NC}\n"
                exit 0
                ;;
            14)
                start_web_portal
                ;;
            15)
                list_instances
                ;;
            16)
                stop_all_instances
                ;;
            *)
                if [ -v "DISTROS[$choice]" ]; then
                    start_container "$choice"
                fi
                ;;
        esac
    done
}

main "$@"
