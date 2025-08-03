const fs = require('fs');
const CONFIG_FILE = '/root/test/new_config.conf';

// 测试读取配置文件
fs.readFile(CONFIG_FILE, 'utf8', (error, data) => {
    if (error) {
        console.error('读取配置文件失败:', error);
        return;
    }

    try {
        const config = JSON.parse(data);
        console.log('配置解析成功:');
        console.log(JSON.stringify(config, null, 2));
    } catch (parseError) {
        console.error('解析配置文件失败:', parseError);
    }
});